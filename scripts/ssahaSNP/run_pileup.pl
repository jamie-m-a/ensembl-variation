#!/usr/bin/env perl
# Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
# Copyright [2016-2018] EMBL-European Bioinformatics Institute
# 
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <helpdesk.org>.

=cut


use strict;
use warnings;
use lib '../import/';
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Variation::DBSQL::DBAdaptor;
use Bio::EnsEMBL::Utils::Exception qw(verbose throw warning);
use Bio::EnsEMBL::Utils::Argument qw( rearrange );
use Data::Dumper;
use Bio::SeqIO;
use FindBin qw( $Bin );
use Getopt::Long;
use ImportUtils qw(dumpSQL debug create_and_load load);

our ($species, $cigar_file, $match_file, $input_file, $output_dir, $align_file, $TMP_DIR, $TMP_FILE, $strain_name, $ssaha_command_dir, $root_dir);

GetOptions('species=s'    => \$species,
	   'cigar_file=s' => \$cigar_file,
	   'match_file=s' => \$match_file,
           'input_file=s' => \$input_file,
           'output_dir=s' => \$output_dir,
           'tmpdir=s'     => \$ImportUtils::TMP_DIR,
           'tmpfile=s'    => \$ImportUtils::TMP_FILE,
           'strain_name=s' => \$strain_name,
		   'ssaha_dir=s' => $ssaha_command_dir,
		   'rootdir=s' => $root_dir,
          );
#my $registry_file ||= $Bin . "/ensembl.registry2";

#usage('-species argument is required') if(!$species);

$TMP_DIR  = $ImportUtils::TMP_DIR;
$TMP_FILE = $ImportUtils::TMP_FILE;
$strain_name ||="tg1";

my $registry_file;
$registry_file ||= $Bin . "/../import/ensembl.registry";
#$registry_file ||= $Bin . "/ensembl.registry" if ($TMP_FILE =~ /venter/);
#$registry_file ||= $Bin . "/ensembl.registry2" if ($TMP_FILE =~ /watson/);

Bio::EnsEMBL::Registry->load_all( $registry_file );

my $cdb = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'core');
my $vdb = Bio::EnsEMBL::Registry->get_DBAdaptor($species,'variation');
my $dbCore = $cdb->dbc;
my $dbVar = $vdb->dbc;
my $slice_adaptor = $cdb->get_SliceAdaptor;
my $buffer = {};

my %seq_region_ids;
my $sth = $dbCore->prepare(qq{SELECT sr.seq_region_id, sr.name
   		              FROM   seq_region_attrib sra, attrib_type at, seq_region sr
  		              WHERE sra.attrib_type_id=at.attrib_type_id 
 	                      AND at.code="toplevel" 
                              AND sr.seq_region_id = sra.seq_region_id 
 		             });
$sth->execute();
while (my ($seq_region_id,$seq_region_name) = $sth->fetchrow_array()) {
  #print "seq_reion_name is $seq_region_name\n";
  $seq_region_ids{$seq_region_name} = $seq_region_id;
}

#read_cigar_file();
#read_match_file();
#make_pileup_reads_file();
#parse_pileup_snp_file();
#merge_pileup_snp();
 #create_vdb();
#PAR_regions();
read_coverage();

sub read_cigar_file {

  debug("Reading cigar_file");
  #cigar file is generated by later step, so run this later
  #my %seq_region_ids = %$seq_region_ids;
  #system("cat $output_dir/ssaha_out*hash |egrep cigar >$output_dir/genome-cigar-raw.dat");
  #system("$ssaha_command_dir/ssaha_cigar $output_dir/genome-cigar-raw.dat $output_dir/genome-cigar.dat");

  $cigar_file ||="$output_dir/genome-cigar.dat";
  my $buffer={};
  open IN, "$cigar_file" or die "can't open cigar_file $!";
  #open OUT, ">$TMP_DIR/$TMP_FILE" or die "can't open tmp_file $!";

  while (<IN>) {
    if (/cigar\::/) {
      #cigar: gnl|ti|904511325 0 778 + 8-1-129041809 73391177 73391953 + 762 M 754 I 1 M 16 I 1 M 6
    my ($cigar,$query_name,$query_start,$query_end,$query_strand,$target_name,$target_start,$target_end,$target_strand,$score,@cigars) = split;
    
    my $target_name1;
    ($target_name1) = $target_name =~ /^(.*)\-.*\-.*$/ if ($target_name =~ /\-/);
    ($target_name1) = $target_name =~ /^.*\:.*\:(.*)\:.*\:.*\:.*$/ if ($target_name =~ /\:/);
    #print "target_name1 is $target_name1\n";
    my $cigar_string;
    while (@cigars) {
      my $tag = shift @cigars;
      my $base = shift @cigars;
      $cigar_string .= $base.$tag;
    }
    $query_strand = ($query_strand eq "+") ? 1 : -1;
    $target_strand = ($target_strand eq "+") ? 1 : -1;
    print_buffered($buffer,"$TMP_DIR/cigar", join ("\t", $query_name,$query_start,$query_end,$query_strand,$seq_region_ids{$target_name1},$target_name,$target_start,$target_end,$target_strand,$score,$cigar_string,$strain_name)."\n");
    } 
  }
  print_buffered($buffer);

  system("mv $TMP_DIR/cigar $TMP_DIR/$TMP_FILE");
  debug("Loading ssahaSNP_feature table");
  
  my $tab_name_ref1 = $dbVar->db_handle->selectall_arrayref(qq{show tables like "ssahaSNP_feature%"});  
  
  if ($tab_name_ref1->[0][0]) {
    load($dbVar,"ssahaSNP_feature", "query_name","query_start","query_end","query_strand","target_seq_region_id","target_name","target_start","target_end","target_strand","score","cigar_string","strain_name");
  }
  else {
    create_and_load($dbVar, "ssahaSNP_feature", "query_name *","query_start i*","query_end i*","query_strand","target_seq_region_id i*","target_name *","target_start i*","target_end i*","target_strand","score","cigar_string","strain_name");
  }
}

sub read_match_file {

  #my %rec_strain_name = %$rec_strain_name;
  my $buffer = {};
  debug("Reading Match file...");

  open IN, "$match_file" or die "can't open match_file $!";
  #open OUT, ">$TMP_DIR/$TMP_FILE" or die "can't open tmp_file $!";

  while (<IN>) {
    #match line looks like: Matches For Query 0 (907 bases): gnl|ti|925271746
    $_ =~ /^.*\:*Matches For Query\s+\d+\s+\((\d+)\s+bases\)\:\s+(.*)$/;
    my $length = $1;
    my $reads_name = $2;
    print_buffered($buffer,"$TMP_DIR/match", "$reads_name\t$length\t$strain_name\n");
  }

  print_buffered($buffer);
  system("mv $TMP_DIR/match $TMP_DIR/$TMP_FILE");
  debug("Loading query_match_length table...");
  my $match_tab_ref = $dbVar->db_handle->selectall_arrayref(qq{show tables like "query_match%"});
  if ($match_tab_ref->[0][0]) {
    load($dbVar,"query_match_length_strain","query_name","length","strain_name");
  }
  else {
    create_and_load($dbVar,"query_match_length_strain","query_name *","length","strain_name");
  }  
}

sub make_pileup_reads_file {

  my $self = shift;
  my $tmp_dir = $self->{'tmpdir'};
  my $tmp_file = $self->{'tmpfile'};
  my $fastq_dir = "$root_dir/fastq/$strain_name";
  my $output_dir = "$root_dir/output_dir/$strain_name";
  my $target_dir = "$root_dir/target_dir";
  my $pileup_dir = "$root_dir/pileup_dir/$strain_name";

  opendir DIR, "$fastq_dir" or die "Failed to open dir : $!";
  my @fastq_files = grep /fastq$/, readdir(DIR);
  #print "files are @reads_dirs\n";
  foreach my $fastq_file (@fastq_files) {
    my $job = "bsub -q normal -J parallel_jobs_$fastq_file -o $pileup_dir/out_parallel_$fastq_file $ssaha_command_dir/parallel_pileup.pl -pileup_dir $pileup_dir -output_dir $output_dir -fastq_dir $fastq_dir -fastq_file $fastq_file";
    print "processing $fastq_file...\n";
    system($job);
    print "job is $job\n";
  }

  my $call = "bsub -q long -K -w 'done(parallel_jobs*)' -J waiting_process sleep 1"; #waits until all variation features have finished to continue
  system($call);

  system("cat $pileup_dir/*cigar.dat >$pileup_dir/genome-cigar.dat");
  system("cat $pileup_dir/*fastq.dat >$pileup_dir/genome-reads.fastq");

  #print "Running pileup SNP...\n";
  #The pileup job needs 15 hours and take 55000 memory on turing. At moment, turing's tmp disk is relatively small, so can't do the folloing, needs to scp files over to turing and send job on turing
  #system("bsub -q hugemem -R'select[mem>55000] rusage[mem=55000]' -o $pileup_dir/out_SNP -f \"$pileup_dir/genome-cigar.dat > /tmp/genome-cigar.dat\" -f \"$pileup_dir/genome-reads.fastq > /tmp/genome-reads.fastq\" -f \"$target_dir/tetraodon.faa > /tmp/tetraodon.faa\" $ssaha_command_dir/ssaha_pileup-turing /tmp/genome-cigar.dat /tmp/tetraodon.faa /tmp/genome-reads.fastq");
  system("bsub -q normal -M7000000 -R'select[mem>7000] rusage[mem=7000]' -o $pileup_dir/out_SNP $ssaha_command_dir/ssaha_pileup $pileup_dir/genome-cigar.dat $pileup_dir/tetraodon.faa $pileup_dir/genome-reads.fastq");
}



sub parse_pileup_snp_file {

  
  my $snp_count;
  my $failed_count;

  open IN, "$input_file" or die "can't open snp_file : $!";

  while (<IN>) {
    next if ($_ !~ /^SNP/);
    my (%base_big,%base_small,%all_letter);
    my ($het,$target_name,$score,$pos,$num_reads,$ref_base,$snp_base,$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t) = split;
    my ($snp_base1,$snp_base2) = split /\//, $snp_base;
    my ($allele_string,$allele_1,$allele_2);
    if ($ref_base !~ /N/i and $snp_base1 =~ /$ref_base/i) {
      $allele_string = "$ref_base/$snp_base2";
    }
    #SNP_hez: 1-1-229942017 30 23995820  6       T C/G 0      3      2      1      0      0     0   0   2   1
    #avoid above case
    elsif ($ref_base !~/N/i and (! $snp_base2 or $snp_base2 =~ /$ref_base/i)) {
      $allele_string = "$ref_base/$snp_base1";
    }
    my ($chr,$start,$end) = split /\-/, $target_name;
    my $seq_region_start = $pos + $start -1; #most chr start =1, but haplotype chr start >1
    if ($score<=10) {
      $allele_string = '\N' if ! $allele_string;
      $failed_count++;
      print_buffered($buffer, "$TMP_DIR/failed_file_$strain_name",join ("\t", $failed_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
    }
    else {
      if (! $allele_string) {
	$allele_string = '\N';
	$failed_count++;
	print_buffered($buffer, "$TMP_DIR/failed_file_$strain_name",join ("\t", $failed_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
      }
      else {
	if (!$snp_base2) {
	  ##have two or more total bases 
	  if (($snp_base1 =~ /a/i and $num_A>1) or ($snp_base1 =~ /c/i and $num_C>1) or ($snp_base1 =~ /g/i and $num_G>1) or ($snp_base1 =~ /t/i and $num_T>1)) {
	    $allele_1 = $snp_base1;
	    $allele_2 = $snp_base1;
	    $snp_count++;
	    print_buffered($buffer, "$TMP_DIR/pileup_file_same_base_$strain_name",join ("\t", $snp_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$allele_1,$allele_2,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
	  }
	  else {
	    $failed_count++;
	    print_buffered($buffer, "$TMP_DIR/failed_file_$strain_name",join ("\t", $failed_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
	  }
	}
	elsif ($snp_base1 and $snp_base2) {
	  #print "chr is $seq_region_ids{$chr},$chr\n";

	  my %rec;
	  $rec{"num_A"} = $num_A;
	  $rec{"num_C"} = $num_C;
	  $rec{"num_G"} = $num_G;
	  $rec{"num_T"} = $num_T;
	  $rec{"num_a"} = $num_a;
	  $rec{"num_c"} = $num_c;
	  $rec{"num_g"} = $num_g;
	  $rec{"num_t"} = $num_t;
	  foreach my $pair ("ac","ca","ag","ga","at","ta","cg","gc","ct","tc","gt","tg") {
	    my ($base1,$base2) = split "", $pair;
	    if ($snp_base1 =~ /$base1/i and $snp_base2 =~ /$base2/i) {
	      my $cap_base1 = uc($base1);
	      my $small_base1 = lc($base1);
	      my $cap_base2 = uc($base2);
	      my $small_base2 = lc($base2);
	      #print "num_G is ", $rec{"num_$cap_base1"},"\n";
	      my $num_cap_base1 = $rec{"num_"."$cap_base1"};
	      my $num_cap_base2 = $rec{"num_"."$cap_base2"};
	      my $num_small_base1 = $rec{"num_"."$small_base1"};
	      my $num_small_base2 = $rec{"num_"."$small_base2"};

	      if ($num_cap_base1-$num_small_base1>1 and $num_cap_base2-$num_small_base2>1 ) {
		#two big alleles, do not use frequency
		$allele_1 = $snp_base1;
		$allele_2 = $snp_base2;
	      }
	      elsif ($num_cap_base1-$num_small_base1>0 or $num_cap_base1>1 and $num_cap_base2-$num_small_base2>0 or $num_cap_base2>1 ) {#one big allele or two small alleles, use ratio to decide homo or hetero
		if ($num_cap_base1<=$num_cap_base2) {
		  if ($num_cap_base1/$num_cap_base2 >= 0.25) {
		    $allele_1 = $snp_base1;
		    $allele_2 = $snp_base2;
		  }
		  elsif ($num_cap_base1/$num_cap_base2 < 0.25 and $snp_base2 !~ /$ref_base/i) {
		    $allele_1 = $snp_base2;
		    $allele_2 = $snp_base2;
		  }
		}
		elsif ($num_cap_base1>$num_cap_base2) {
		  if ($num_cap_base2/$num_cap_base1 >= 0.25) {
		    $allele_1 = $snp_base2;
		    $allele_2 = $snp_base1;
		  }
		  elsif ($num_cap_base2/$num_cap_base1 < 0.25 and $snp_base1 !~ /$ref_base/i) {
		    #print "$seq_region_ids{$chr},$seq_region_start,$snp_base,$ref_base\n";
		    $allele_1 = $snp_base1;
		    $allele_2 = $snp_base1;
		  }
		}
	      }

	      if ($allele_1 and $allele_2) {
		$snp_count++;
		print_buffered($buffer, "$TMP_DIR/pileup_file_$strain_name",join ("\t", $snp_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$allele_1,$allele_2,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
	      }
	      else {#one allele only have one base and it's qual<25
		$failed_count++;
		print_buffered($buffer, "$TMP_DIR/failed_file_$strain_name",join ("\t", $failed_count,$seq_region_ids{$chr},$chr,$seq_region_start,$num_reads,$ref_base,$snp_base,$allele_string,$score,$strain_name,join(",",$num_A,$num_C,$num_G,$num_T,$num_N,$num_hef,$num_a,$num_c,$num_g,$num_t))."\n");
	      }
	    }
	  }
	}
      }
    }
  }

  print_buffered($buffer);

  system("mv $TMP_DIR/failed_file_$strain_name $TMP_DIR/$TMP_FILE");
  create_and_load($dbVar,"failed_snps_$strain_name","failed_count i*","seq_region_id i*","chr *","seq_region_start i*","num_reads","ref_base","snp_base","allele_string","score","individual_name","ACGTNacgt");
  system("mv $TMP_DIR/pileup_file_$strain_name $TMP_DIR/$TMP_FILE");
  create_and_load($dbVar,"pileup_snp_$strain_name","snp_count i*","seq_region_id i*","chr *","seq_region_start i*","num_reads","ref_base","snp_base","allele_string","allele_1","allele_2","score","individual_name","ACGTNacgt");
  system("mv $TMP_DIR/pileup_file_same_base_$strain_name $TMP_DIR/$TMP_FILE");
  create_and_load($dbVar,"pileup_snp_same_base_$strain_name","snp_count i*","seq_region_id i*","chr *","seq_region_start i*","num_reads","ref_base","snp_base","allele_string","allele_1","allele_2","score","individual_name","ACGTNacgt");


  $dbVar->do(qq{CREATE TABLE IF NOT EXISTS pileup_snp LIKE pileup_snp_$strain_name});
  $dbVar->do(qq{INSERT INTO pileup_snp SELECT * FROM pileup_snp_$strain_name});
  $dbVar->do(qq{INSERT INTO pileup_snp SELECT * FROM pileup_snp_same_base_$strain_name});
}

sub merge_pileup_snp {

  my $variation_name = "temptgu";
 
  debug("Create table pileup_snp_merge...");
  
  $dbVar->do(qq{CREATE TABLE IF NOT EXISTS pileup_snp_merge (
                variation_id int(10) unsigned not null auto_increment,
                name varchar(25),
                chr varchar(20),
                seq_region_id int(15),
                seq_region_start int(15),
                allele_string varchar(255),
                individual_name varchar(30),
                primary key (variation_id),
                key pos_idx(seq_region_id,seq_region_start)
            )
            });
  
  $dbVar->do(qq{INSERT INTO pileup_snp_merge (name,chr,seq_region_id,seq_region_start,allele_string,individual_name) 
                SELECT DISTINCT "$variation_name" as name, chr, seq_region_id,seq_region_start,group_concat(allele_string) as allele_string, group_concat(individual_name)
                FROM pileup_snp 
                GROUP BY seq_region_id,seq_region_start
                });

  my $sth = $dbVar->prepare(qq{SELECT variation_id,allele_string FROM pileup_snp_merge
                               WHERE length(allele_string)>3});
  my ($variation_id,$allele_string);
  $sth->execute();
  $sth->bind_columns(\$variation_id,\$allele_string);
  while($sth->fetch()) {
    my (%rec_snp,$ref_allele,$snp_allele);
    my @alleles = split /\,/, $allele_string;
    foreach my $allele (@alleles) {
      ($ref_allele,$snp_allele) = split /\//, $allele;
      #print "$ref_allele,$snp_allele\n";
      $rec_snp{$snp_allele}=1;
    }
    my $allele_string_new = "$ref_allele/" . join "/", keys %rec_snp;
    #print "allele_string_new is $allele_string_new\n";
    $dbVar->do(qq{UPDATE pileup_snp_merge SET allele_string = "$allele_string_new"
                  WHERE variation_id = $variation_id});
  }
}

sub create_vdb {

  my %rec_strain = ("tg1" => 1);

  my $individual_type_id = 3;
  my $pop_size = keys %rec_strain;
  $pop_size ||=1;
  my $ind_pop_name = "refstrain";
  my $ind_sample_pop_desc = "Population for $pop_size individual(s)";
  my $ind_sample_desc = "Individual within population $ind_pop_name";



  debug("Inserting into population, individual and sample tables");

  $dbVar->do(qq{INSERT INTO sample (name,description) values ("$ind_pop_name","$ind_sample_pop_desc")});
  my $population_ind_sample_id = $dbVar->db_handle->{'mysql_insertid'};
  $dbVar->do(qq{INSERT INTO population (sample_id) values ($population_ind_sample_id)});

  foreach my $strain_name (keys %rec_strain) {
    $dbVar->do(qq{INSERT INTO sample (name,size,description) values ("$strain_name",NULL,"$ind_sample_desc")});
    my $individual_sample_id = $dbVar->db_handle->{'mysql_insertid'};
    $dbVar->do(qq{INSERT INTO individual (sample_id,individual_type_id) values ($individual_sample_id, $individual_type_id)});
    $dbVar->do(qq{INSERT INTO individual_population (individual_sample_id,population_sample_id) values ($individual_sample_id,$population_ind_sample_id)});
  }

  debug("Creating database now...");

  my $source_name = "ENSEMBL"; #needs change everytime
  my $var_pre_name = "ENSEMBL";
  my $variation_name = "ENSTGUSNP";###needs change for different species
  my $length_name = length($variation_name);

    $dbVar->do(qq{INSERT INTO source (name) values ("$source_name")});
    my $source_id = $dbVar->{'mysql_insertid'};
    debug("Insert into variation table...");

    $dbVar->do(qq{ALTER TABLE variation add column internal_name varchar(50) unique key});
    $dbVar->do(qq{INSERT IGNORE INTO variation (variation_id,source_id,name,internal_name) select snp.variation_id,s.source_id as source_id,concat(snp.name,snp.variation_id) as name,concat("$source_name\_",snp.chr,"-",snp.seq_region_start) as internal_name from source s, pileup_snp_merge snp});


    dumpSQL($dbCore,qq{SELECT sr.seq_region_id, sr.name, sr.length
                                FROM   seq_region_attrib sra, attrib_type at, seq_region sr
                                WHERE sra.attrib_type_id=at.attrib_type_id 
                                AND at.code="toplevel" 
                                AND sr.seq_region_id = sra.seq_region_id 
                     });
   create_and_load($dbVar,"tmp_seq_region","seq_region_id i*","seq_region_name *","seq_region_length");

 debug("Insert into variation_feature table... NOTE ABOUT Y CHROMOSOME");
 $dbVar->do(qq{INSERT INTO variation_feature (seq_region_id,seq_region_start,seq_region_end,seq_region_strand,variation_id,allele_string,variation_name,map_weight,flags,source_id,validation_status,consequence_type)
             SELECT ts.seq_region_id,snp.seq_region_start,snp.seq_region_start,1,v.variation_id,snp.allele_string,v.name,1,"genotyped",s.source_id,NULL,"INTERGENIC"
             FROM tmp_seq_region ts,variation v,pileup_snp_merge snp, source s
             WHERE s.name = "$source_name"
             AND snp.chr = ts.seq_region_name
             AND v.variation_id = snp.variation_id
             });

#   debug("Insert into variation_feature table... ABOUT Y CHROMOSOME");
#   $dbVar->do(qq{create table vf_y_top select * from variation_feature where seq_region_id=226054 and seq_region_start>=1 and seq_region_start<=2709520});
#   $dbVar->do(qq{insert into vf_y_top select * from variation_feature where seq_region_id=226054 and seq_region_start>=57443438 and seq_region_start<=57772954});
#   $dbVar->do(qq{update vf_y_top set seq_region_id=226031});
#   $dbVar->do(qq{insert into variation_feature (seq_region_id,seq_region_start,seq_region_end,seq_region_strand,variation_id,allele_string,variation_name,map_weight,flags,source_id,validation_status,consequence_type) select seq_region_id,seq_region_start,seq_region_end,seq_region_strand,variation_id,allele_string,variation_name,map_weight,flags,source_id,validation_status,consequence_type from vf_y_top});
#   #Query OK, 5020 rows affected (0.10 sec)
#   #Records: 5020  Duplicates: 0  Warnings:

  debug("Insert into flanking_sequence table...");
  $dbVar->do(qq{INSERT IGNORE INTO flanking_sequence (variation_id,up_seq,down_seq,up_seq_region_start,up_seq_region_end,down_seq_region_start,down_seq_region_end,seq_region_id,seq_region_strand)
              SELECT vf.variation_id,NULL,NULL,if(vf.seq_region_start-101<1,1,vf.seq_region_start-101),vf.seq_region_start-1,vf.seq_region_end+1,if(vf.seq_region_end+101>sr.seq_region_length,sr.seq_region_length,vf.seq_region_end+101),vf.seq_region_id,vf.seq_region_strand
              FROM variation_feature vf, tmp_seq_region sr
              WHERE vf.seq_region_id = sr.seq_region_id
               });

  debug("Insert into allele table...");
  $dbVar->do(qq{CREATE UNIQUE INDEX unique_allele_idx ON allele (variation_id,allele(2),frequency,sample_id)});

  foreach my $num (1,3,5) {
    $dbVar->do(qq{INSERT IGNORE INTO allele (variation_id,allele,sample_id)
                SELECT v.variation_id,substring(snp.allele_string,$num,1) as allele,null as sample_id
                FROM variation v, pileup_snp_merge snp
                WHERE v.variation_id = snp.variation_id
                });
  }
  $dbVar->do(qq{DELETE FROM allele WHERE allele ="";});

  #$dbVar->do("DROP INDEX unique_allele_idx ON allele"); need it in the following par regions

  if ($pop_size == 1) {
    $dbVar->do(qq{CREATE TABLE IF NOT EXISTS tmp_individual_genotype_single_bp (
                            variation_id int not null,allele_1 varchar(255),allele_2 varchar(255),sample_id int,
                            key variation_idx(variation_id),
                            key sample_idx(sample_id)
                            ) MAX_ROWS = 100000000
               });

    $dbVar->do(qq{create table pileup_snp_new select m.variation_id,p.allele_1,p.allele_2,p.individual_name from pileup_snp p, pileup_snp_merge m where p.seq_region_id=m.seq_region_id and p.seq_region_start=m.seq_region_start});

    debug("Insert into tmp_individual_genotype_single_bp table...");
    $dbVar->do(qq{INSERT INTO tmp_individual_genotype_single_bp (variation_id,allele_1,allele_2,sample_id)
                SELECT  v.variation_id,snp.allele_1,snp.allele_2,s.sample_id
                FROM variation v, pileup_snp_new snp, sample s
                WHERE v.variation_id = snp.variation_id
                AND snp.individual_name = s.name
                });
  }
}

#PAR regions are identical regions between chr Y and X. We need to copy variations from X to Y
sub PAR_regions{

  my $ae_adaptor =  $cdb->get_AssemblyExceptionFeatureAdaptor( $species, 'Core', 'AssemblyExceptionFeature' );
  my $slice = $slice_adaptor->fetch_by_region( 'Chromosome', 'Y' );
  my @exceptions = @{ $ae_adaptor->fetch_all_by_Slice($slice) }; #get the PAR regions between chr Y->X

  my $last_variation_feature_id = get_last_table_id("variation_feature");

  get_variations(\@exceptions,$last_variation_feature_id); #method to get all variations in PAR region

  #import the 3 table

#   my $sql = qq{LOAD DATA LOCAL INFILE "$TMP_DIR/variation_feature.txt" INTO TABLE variation_feature (variation_feature_id,seq_region_id,seq_region_start,seq_region_end,seq_region_strand,variation_id,allele_string,variation_name,map_weight,flags, source_id)};
#   $dbVar->do($sql);
#   unlink("$TMP_DIR/variation_feature.txt");
#   $sql = qq{LOAD DATA LOCAL INFILE "$TMP_DIR/flanking_sequence.txt" INTO TABLE flanking_sequence (variation_id,up_seq_region_start,up_seq_region_end,down_seq_region_start,down_seq_region_end,seq_region_id,seq_region_strand)};
#   $dbVar->do($sql);
#   #unlink("$TMP_DIR/flanking_sequence.txt");
#   get_allele_genptype();
}

sub get_variations{
  my $exceptions = shift;
  my $last_variation_feature_id = shift;

#  $dbVar->do(qq{CREATE TABLE IF NOT EXISTS tmp_varid (
#				       variation_id int not null,
#				       variation_id_new int,
#				       primary key variation_idx(variation_id))});

  foreach my $exception (@$exceptions) {
    my $target_seq_region_id = $exception->slice->get_seq_region_id();
    my $target_start = $exception->start(); #Y coordinates
    my $target_end = $exception->end();
    my $seq_region_id = $exception->alternate_slice->get_seq_region_id();
    my $start = $exception->alternate_slice()->start(); #X coordinates
    my $end = $exception->alternate_slice()->end();

    my ($variation_id,$variation_name,$seq_region_start,$seq_region_strand,$allele_string);
    my $snp_pos; #position of the SNP relative to the beginning to the region
    my $sth = $dbVar->prepare(qq{SELECT variation_id,variation_name,seq_region_start,seq_region_strand,allele_string FROM variation_feature WHERE seq_region_id = ? and seq_region_start >= ? and seq_region_end <= ? and seq_region_start <= ?});
    $sth->bind_param(1,$seq_region_id);
    $sth->bind_param(2,$start);
    $sth->bind_param(3,$end);
    $sth->bind_param(4,$end);
    $sth->execute();
    $sth->bind_columns(\$variation_id,\$variation_name,\$seq_region_start,\$seq_region_strand,\$allele_string);

    while ($sth->fetch){
        $snp_pos = $seq_region_start - $start; #the position of the snp relative to the beginning of the PAR region
        #write_file("variation.txt",$last_variation_id+1,1,"ENSSNP".($last_variation_name+1));
        write_file("variation_feature.txt",$last_variation_feature_id+1,$target_seq_region_id,$snp_pos+$target_start,$snp_pos+$target_start,$seq_region_strand,$variation_id,$allele_string,$variation_name,1,"genotyped",1);
        #write_file("flanking_sequence.txt",$last_variation_id+1,$snp_pos+$target_start - 1 - 100,$snp_pos+$target_start - 1,$snp_pos+$target_start  +1, $snp_pos+$target_start + 1 + 100,$target_seq_region_id,$seq_region_strand);
        #$last_variation_id++;
        $last_variation_feature_id++;
        #$last_variation_name++;
	#$dbVar->do(qq{INSERT INTO tmp_varid (variation_id,variation_id_new) values($variation_id,$last_variation_id)});
    }
  }
}

sub get_allele_genptype {


  $dbVar->do(qq{INSERT INTO allele (variation_id,allele,sample_id)
                SELECT t.variation_id_new as variation_id,a.allele,a.sample_id
                FROM tmp_varid t, allele a
                WHERE t.variation_id=a.variation_id
               });

  $dbVar->do(qq{INSERT INTO tmp_individual_genotype_single_bp (variation_id,allele_1,allele_2,sample_id)
                SELECT tv.variation_id_new as variation_id,tg.allele_1,tg.allele_2,tg.sample_id
                FROM tmp_varid tv, tmp_individual_genotype_single_bp tg
                WHERE tv.variation_id=tg.variation_id
               });
}

#function to return the last id used in the table tablename (the id must be called "tablename_id")
sub get_last_table_id{

    my $tablename = shift;

    my $max_id;
    my $sth = $dbVar->prepare(qq{SELECT MAX($tablename\_id) from $tablename});
    $sth->execute();
    $sth->bind_columns(\$max_id);
    $sth->fetch;
    $sth->finish();

    return $max_id if (defined $max_id);
    return 0 if (!defined $max_id);
}

sub write_file{
    my $filename = shift;
    my @values = @_;

    open FH, ">>$TMP_DIR/$filename" || die "Could not open file with information: $!\n
";
    my @a = map {defined($_) ? $_ : '\N'} @values; #to replace undefined values by \N in the file
    print FH join("\t", @a), "\n";
    close FH || die "Could not close file with information: $!\n";
    
}


#function to return the last id used in the table tablename (the id must be called "tablename_id")
sub get_last_variation_name{
    #my $dbSanger = shift;


    my $max_id;
    my $sth = $dbVar->prepare(qq{SELECT max(round(substring(name,7))) from variation});
    $sth->execute();
    $sth->bind_columns(\$max_id);
    $sth->fetch;
    $sth->finish();

    return $max_id if (defined $max_id);
    return 0 if (!defined $max_id);
}

sub read_coverage {

  debug("reading read coverage data...");
  my $buffer={}; #buffer to store the lines to be written

  open IN, "$cigar_file" or die "can't open cigar_file $!";

  while (<IN>) {
    if (/^cigar/) {
      #cigar: gnl|ti|904511325 0 778 + 8-1-129041809 73391177 73391953 + 762 M 754 I 1 M 16 I 1 M 6
      my $cigar_line = $_;
    my ($cigar,$query_name,$query_start,$query_end,$query_strand,$target_name,$target_start,$target_end,$target_strand,$score,@cigars) = split;

      my ($null,$null1,$null2,$chr);
      ($chr) = split /\-/, $target_name if $target_name =~ /\-/;
      ($null,$null1,$chr,$null2) = split /\:/, $target_name if $target_name =~ /\:/;

      ($target_end, $target_start) = ($target_start, $target_end) if ($target_end < $target_start);

      my $file;
      if ($dbVar->dbname =~ /platypus/) {
	if ($chr =~ /Contig/) {
	  $file = "Contig\.mapped";
	}
	elsif ($chr =~ /Ultra/) {
	  $file = "Ultra\.mapped";
	}
	else {
	  $file = "Chr\.mapped";
	}
      }
      else {
	if ($chr =~ /^NT/) {
	  $file = "NT.mapped";
	}
	else {
	  $file = "$chr.mapped";
	}
      }
      print_buffered($buffer,"$TMP_DIR/$file",join("\t",$strain_name,$target_start,$target_end)."\n");
    }
  }
  print_buffered($buffer); #flush the buffer
}

sub print_buffered {
    my $buffer = shift;
    my $filename = shift;
    my $text = shift;

    local *FH;

    if( ! $filename ) {
        # flush the buffer
        foreach my $file (keys %{$buffer}){
            open( FH, ">>$file" ) or die;
            print FH $buffer->{ $file };
            close FH;
        }
	%{$buffer}=();

    } else {
        $buffer->{ $filename } .= $text;
        if( length( $buffer->{ $filename } ) > 10_000 ) {
            open( FH, ">>$filename" ) or die;
            print FH $buffer->{ $filename };
            close FH;
            $buffer->{ $filename } = '';
        }
    }
}
