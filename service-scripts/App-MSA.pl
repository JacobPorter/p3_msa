#The MSA application with variance analysis.

use Bio::KBase::AppService::AppScript;
use Bio::KBase::AppService::AppConfig;

use strict;
use P3DataAPI;
use Data::Dumper;
use File::Basename;
use File::Slurp;
use LWP::UserAgent;
use JSON::XS;
use JSON;
use IPC::Run qw(run);
use Cwd;
use Clone;
use URI::Escape;

my $script = Bio::KBase::AppService::AppScript->new(\&process_fasta);
my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;

my %aacode = (
TTT => "F", TTC => "F", TTA => "L", TTG => "L",
TCT => "S", TCC => "S", TCA => "S", TCG => "S",
TAT => "Y", TAC => "Y", TAA => "*", TAG => "*",
TGT => "C", TGC => "C", TGA => "*", TGG => "W",
CTT => "L", CTC => "L", CTA => "L", CTG => "L",
CCT => "P", CCC => "P", CCA => "P", CCG => "P",
CAT => "H", CAC => "H", CAA => "Q", CAG => "Q",
CGT => "R", CGC => "R", CGA => "R", CGG => "R",
ATT => "I", ATC => "I", ATA => "I", ATG => "M",
ACT => "T", ACC => "T", ACA => "T", ACG => "T",
AAT => "N", AAC => "N", AAA => "K", AAG => "K",
AGT => "S", AGC => "S", AGA => "R", AGG => "R",
GTT => "V", GTC => "V", GTA => "V", GTG => "V",
GCT => "A", GCC => "A", GCA => "A", GCG => "A",
GAT => "D", GAC => "D", GAA => "E", GAG => "E",
GGT => "G", GGC => "G", GGA => "G", GGG => "G",
);

my $rc = $script->run(\@ARGV);

exit $rc;


sub process_fasta
{
    my($app, $app_def, $raw_params, $params) = @_;

    print "Proc MSA Var ", Dumper($app_def, $raw_params, $params);
    my $token = $app->token();
    my $data_api_module = P3DataAPI->new($data_api, $token);
    my $output_folder = $app->result_folder();

    #
    # Create an output directory under the current dir. App service is meant to invoke
    # the app script in a working directory; we create a folder here to encapsulate
    # the job output.
    #
    # We also create a staging directory for the input files from the workspace.
    #

    my $cwd = getcwd();
    my $work_dir = "$cwd/work";
    my $stage_dir = "$cwd/stage";

    -d $work_dir or mkdir $work_dir or die "Cannot mkdir $work_dir: $!";
    -d $stage_dir or mkdir $stage_dir or die "Cannot mkdir $stage_dir: $!";

    my $data_api = Bio::KBase::AppService::AppConfig->data_api_url;
    my $dat = { data_api => $data_api };
    my $sstring = encode_json($dat);

    #
    # Read parameters and discover input files that need to be staged.
    #
    # Make a clone so we can maintain a list of refs to the paths to be
    # rewritten.
    #
    my %in_files;
    my $params_to_app = Clone::clone($params);
    #
    # Count the number of files.
    #
    my $file_count = 0;
    if (exists($params_to_app->{fasta_files})) {
        $file_count = $file_count + scalar(@{$params_to_app->{fasta_files}});
    }
    if (exists($params_to_app->{feature_groups})) {
        $file_count = $file_count + scalar(@{$params_to_app->{feature_groups}});
    }
    if (length($params_to_app->{fasta_keyboard_input}) >= 1) {
        $file_count = $file_count + 1;
    }
    say STDERR "Number of files: $file_count.";
    my $prefix = $params_to_app->{output_file};
    #
    # Determine if the data is represented as DNA or protein.
    #
    my $dna = 1; # Use the DNA alphabet.
    my $in_type = "feature_dna_fasta";
    if (substr($params_to_app->{alphabet}, 0, 1) eq "p") {
    	$dna = 0; # Use the amino acid, protein alphabet.
	    $in_type = "feature_protein_fasta";
    }
    #
    # Write files to the staging directory.
    #
    my @to_stage;

    my $aligned_exists = 0;
    my $mixed = 0;
    for my $read_tuple (@{$params_to_app->{fasta_files}}) {
        for my $read_name (keys %{$read_tuple}) {
            if($read_name eq "file") {
                my $nameref = \$read_tuple->{$read_name};
                $in_files{$$nameref} = $nameref;
                push(@to_stage, $$nameref);
            }
            else {
                if(index($read_tuple->{$read_name}, "aligned") != -1) {
                    $aligned_exists = 1;
                }
                if (index($read_tuple->{$read_name}, "protein") != -1) {
                    $mixed = 1;
                }
            }
        }
    }
    if ($mixed == 1) {
        $dna = 0;
        $in_type = "feature_protein_fasta";
    }
    say STDERR "Alignment already present: $aligned_exists";
    say STDERR "Using DNA?: $dna Protein files exist: $mixed";
    my $staged = {};
    if (@to_stage)
    {
        warn Dumper(\%in_files, \@to_stage);
        $staged = $app->stage_in(\@to_stage, $stage_dir, 1);
        while (my($orig, $staged_file) = each %$staged)
        {
            my $path_ref = $in_files{$orig};
            $$path_ref = $staged_file;
        }
    }
    #
    # Download feature groups in a file.
    #
    my $ofile = "$stage_dir/feature_groups.fasta";
    open(F, ">$ofile") or die "Could not open $ofile";
    for my $feature_name (@{$params_to_app->{feature_groups}}) {
	    my $ids = $data_api_module->retrieve_patricids_from_feature_group($feature_name);
	    my $seq = "";
	    if ($dna) {
		$seq = $data_api_module->retrieve_nucleotide_feature_sequence($ids);
	    } else {
		$seq = $data_api_module->retrieve_protein_feature_sequence($ids);
	    }
	    for my $id (@$ids) {
		    my $out = ">$id\n" . $seq->{$id} . "\n";
    		    print F $out;
	    }
    }
    if (exists($params_to_app->{feature_groups})) {
    	push @{ $params_to_app->{fasta_files} }, {"file" => $ofile, "type" => $in_type};
	close(F);
	# delete $params_to_app->{feature_groups};
    }
    #
    # Put keyboard input into a file.
    #
    my $text_input_file = "$stage_dir/fasta_keyboard_input.fasta";

    # my $bool = is_aa($params_to_app->{fasta_keyboard_input});
    # print "is input aa? $bool";
    if ((not (is_aa($params_to_app->{fasta_keyboard_input}))) && not $dna) {
        convert_aa_file($params_to_app->{fasta_keyboard_input}, $text_input_file, 0);
    } else {
        open(FH, '>', $text_input_file) or die "Cannot open $text_input_file: $!";
        print FH $params_to_app->{fasta_keyboard_input};
        close(FH);
    }
    push @{ $params_to_app->{fasta_files} }, {"file" => $text_input_file, "type" => $in_type};
    #
    # Combine all files into one input.fasta file.
    #
    my $work_fasta = "$work_dir/input.fasta";
    open(IN, '>', $work_fasta) or die "Cannot open $work_fasta: $!";
    for my $read_tuple (@{$params_to_app->{fasta_files}}) {
    	my $filename = $read_tuple->{file};
        my $convert = 0;
        if ((index($read_tuple->{type}, "dna") != -1) && (not $dna)) {
            $convert = 1;
        }
        open my $fh, '<', $filename or die "Cannot open $filename: $!";
        my $seq_line = "";
        while ( my $line = <$fh> ) {
            my $print_me = 1;
            chomp; # remove newlines
            s/#.*//; # remove comments
            s/;.*//; # remove comments
            s/^\s+//;  # remove leading whitespace
            s/\s+$//; # remove trailing whitespace
            next if(length($line) <= 0);
            if ($aligned_exists && $file_count > 1 && substr($line, 0, 1) ne ">") {
                $line =~ tr/-_.~*//d; # Remove indels from alignments if other files are present.
            }
            if ($convert && substr($line, 0, 1) ne ">") {
                chomp($line);
                $seq_line = $seq_line . $line;
                $print_me = 0;
            } elsif ($convert) {
                if ($seq_line) {
                    print IN convert_aa_line(uc $seq_line) . "\n";
                }
                $seq_line = "";
            }
            if ($print_me) {
                print IN $line;
            }
        }
        if ($seq_line) {
            print IN convert_aa_line(uc $seq_line) . "\n";
        }
        close($fh);
    }
    close(IN);
    #
    # Run the multiple sequence aligner.
    #
    my $recipe = lc($params_to_app->{aligner});
    if ($aligned_exists && $file_count == 1) {
        rename "$work_dir/input.fasta", "$work_dir/output.afa";
    }
    elsif ($recipe eq "muscle") {
    	my @muscle_cmd =  ("muscle", "-in", "$work_dir/input.fasta", "-fastaout", "$work_dir/output.afa", "-clwout", "$work_dir/$prefix.aln");
        run_cmd(\@muscle_cmd);
    } else {
        die "Recipe not found: $recipe\n";
    }
    # Run the SNP analysis.
    my @cmd = ("snp_analysis", "-r", "$work_dir", "-x");
    if ($dna) {
    	push @cmd, "-n";
    }
    run_cmd(\@cmd);
    rename "$work_dir/cons.fasta", "$work_dir/$prefix.cons.fasta";
    rename "$work_dir/output.afa", "$work_dir/$prefix.afa";
    #
    # Create figures.
    #
    @cmd = ("snp_analysis_figure", "$work_dir/foma.table", "$work_dir/$prefix");
    run_cmd(\@cmd);
    #
    # Copy output to the workspace.
    #
    rename "$work_dir/foma.table", "$work_dir/$prefix.tsv";
    my $out_type = "aligned_protein_fasta";
    if ($dna) {
        $out_type = "aligned_dna_fasta";
    }
    my @output_suffixes = (
        [qr/\.afa$/, $out_type],
        [qr/\.aln$/, "txt"],
        [qr/\.cons\.fasta$/, "txt"],
        [qr/\.tsv$/, "tsv"],
        [qr/\.table$/, "tsv"],
        [qr/\.png$/, "png"],
        [qr/\.svg$/, "svg"],
        );
    opendir(D, $work_dir) or die "Cannot opendir $work_dir: $!";
    my @files = sort { $a cmp $b } grep { -f "$work_dir/$_" } readdir(D);
    my $output=1;
    for my $file (@files)
    {
	for my $suf (@output_suffixes)
	{
	    if ($file =~ $suf->[0])
	    {
 	    	$output=0;
		my $path = "$output_folder/$file";
		my $type = $suf->[1];
		$app->workspace->save_file_to_file("$work_dir/$file", {}, "$output_folder/$file", $type, 1,
					       (-s "$work_dir/$file" > 10_000 ? 1 : 0), # use shock for larger files
					       $token);
	    }
	}
    }
    #
    # Clean up staged input files.
    #
    while (my($orig, $staged_file) = each %$staged)
    {
	unlink($staged_file) or warn "Unable to unlink $staged_file: $!";
    }
    unlink($text_input_file) or warn "Unable to unlink $text_input_file: $!";
    unlink($ofile) or warn "Unable to unlink $ofile: $!";
    return $output;
}

sub run_cmd() {
    my $cmd = $_[0];
    my $ok = run(@$cmd);
    if (!$ok)
    {
        die "Command failed: @$cmd\n";
    }
}

sub is_aa {
    my ($file_str) = @_;
    open my $fh, '<', \$file_str or die $!;
    while (my $line = <$fh>) {
        if ((substr($line, 0, 1) ne ">") and not($line =~ /^[ACTGNactgn]+$/)) {
            return 1;
        }
    }
    close $fh or die $!;
    return 0;
}

sub convert_aa_line {
    my ($line) = @_;
    chomp($line);
    my @codons = unpack '(A3)*', $line;
    my @aminoAcids = map { exists $aacode{$_} ? $aacode{$_} : "X" } @codons;
    return join('', @aminoAcids);
}

sub convert_aa_file {
    my($in_file, $out_file, $is_file) = @_;

    # my $count = 0;
    if ($is_file) {
        open(INF, "<", $in_file) or die "Couldn't open file $in_file. $!";
    } else {
        open(INF, "<", \$in_file) or die "Couldn't open string. $!";
    }
    open(OUTF, ">", $out_file) or die "Couldn't open file $out_file. $!";
    while (my $line = <INF>) {
        if (substr($line, 0, 1) eq ">") {
            print OUTF "$line";
        } else {
            chomp($line);
            my @codons = unpack '(A3)*', $line;
            my @aminoAcids = map { exists $aacode{$_} ? $aacode{$_} : "?" } @codons;
            my $stuff = join('', @aminoAcids);
            print OUTF "$stuff\n";
        }
    # 	$count = $count + 1;
    }
    close INF or die $!;
    close OUTF or die $!;
}