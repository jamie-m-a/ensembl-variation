#!/usr/bin/env python3
import urllib.request
from urllib.parse import urlencode
import csv
import os
import json
import operator
import warnings
from collections import OrderedDict
from math import isclose
import re

# Customise warning messages
def customshowwarning(message, category, filename, lineno, file=None, line=None):
    print("WARNING:", message)
warnings.showwarning = customshowwarning

# Parse arguments
import argparse
parser = argparse.ArgumentParser(
  description='Output file with MaveDB scores mapped to variants')
parser.add_argument('--vr', type=str,
                    help="path to file containg Variant Recoder output with 'vcf_string' enabled (optional)")
parser.add_argument('--mappings', type=str,
                    help="path to file with MaveDB mappings")
parser.add_argument('--urn', type=str,
                    help="MaveDB URN (such as 'urn:mavedb:00000046-a-2')")
parser.add_argument('-o', '--output', type=str,
                    help="path to output file")
parser.add_argument('--round', type=int,
                    help="Number of decimal places for rounding values (default: not used)")
args = parser.parse_args()

def load_vr_output (f):
  """Load Variant Recoder output"""
  data = json.load(open(f))

  matches = {}
  for result in data:
    for allele in result:
      info = result[allele]

      if type(info) is list and "Unable to parse" in info[0]:
        continue

      hgvs = info["input"]
      for string in info["vcf_string"]:
        chr, start, ref, alt = string.split('-')
        end = int(start) + len(alt) - 1
        dict = OrderedDict([("HGVSp", hgvs),
                            ("chr",   chr),
                            ("start", start),
                            ("end",   end),
                            ("ref",   ref),
                            ("alt",   alt)])

        if hgvs not in matches:
          matches[hgvs] = []
        matches[hgvs].append(dict)
  return matches

def load_HGVSp_to_variant_matches (f):
  """Load HGVSp to variant matches"""
  matches = {}
  with open(f) as csvfile:
    reader = csv.DictReader(csvfile, delimiter="\t")
    for row in reader:
      hgvs = row['HGVSp']
      if hgvs not in matches:
        matches[hgvs] = []
      matches[hgvs].append(row)
  return(matches)

def load_scores (f):
  """Load MaveDB scores"""
  scores = []
  with open(scores_file) as csvfile:
    reader = csv.DictReader(csvfile)
    for row in reader:
      # get index to sort data (required to match scores with MaveDB mappings)
      row['index'] = int(row['accession'].split("#")[1])
      scores.append(row)
  scores = sorted(scores, key=operator.itemgetter('index'))
  return scores

chrom = None
def get_chromosome (hgvs):
  """Lookup chromosome name in Ensembl REST API (unless already stored)"""
  global chrom
  if (chrom is None):
    chrom = hgvs.split(":")[0]
    url   = f"https://rest.ensembl.org/info/assembly/homo_sapiens/{chrom}?"
    data  = urlencode({"synonyms": 1, "content-type": "application/json"})
    res   = urllib.request.urlopen(url + data).read()
    res   = json.loads(res)
    chrom = [each["name"] for each in res["synonyms"] if each['dbname'] == "UCSC"][0]
    chrom = chrom.replace("chr", "")
  return chrom

def join_information (hgvs, mapped_info, row, extra):
  """Join variant and MaveDB score information for a given HGVS"""
  var = mapped_info['variation']
  ref = mapped_info['vrs_ref_allele_seq']

  mapped = OrderedDict(
    [("chr",   get_chromosome(hgvs)),
     ("start", var["location"]["interval"]["start"]["value"] + 1),
     ("end",   var["location"]["interval"]["end"]["value"]),
     ("ref",   ref),
     ("alt",   var["state"]["sequence"]),
     ("hgvs",  hgvs)])
  mapped.update(extra)
  mapped.update(row)
  return [mapped]

def match_information (hgvs, matches, row, extra):
  """Match a given HGVS to join variant and MaveDB score information"""
  out = []
  
  if hgvs not in matches:
    warnings.warn(f"{hgvs} not found in HGVSp-variant matches")
    return out

  for match in matches[hgvs]:
    mapped = match
    mapped['hgvs'] = match['HGVSp']
    mapped.update(extra)
    mapped.update(row)
    out.append(mapped)
  return out

def map_variant_to_MaveDB_scores (matches, mapped_info, row, extra):
  hgvs = mapped_info['expressions'][0]['value']
  if matches is None:
    # HGVS genomic coordinates
    return join_information(hgvs, mapped_info, row, extra)
  else:
    # HGVS protein matches
    return match_information(hgvs, matches, row, extra)

def get_next_mapping(m, index):
  """Get next mapping in list of mappings"""
  if index >= len(m):
    mapping = m[-1]

  while index < len(m):
    mapping = m[index]
    if mapping['score'] is None:
      index += 1
    else:
      break
  return mapping, index

def round_float_columns(row):
  """Round all values that are float"""
  if args.round is not None:
    for i in row.keys():
      try:
        rounded = round(float(row[i]), args.round)
        # Avoid rounding integers
        row[i] = '{0:g}'.format(rounded)
      except:
        # Not a number
        pass
  return row

def map_scores_to_variants (scores, mappings, matches=None):
  """Map MaveDB scores to variants"""

  if mappings['target'] is not None and mappings['target']['refseq'] is not None:
    refseq = mappings['target']['refseq']['identifier']
  else:
    refseq = None
  pubmed = ",".join([i['identifier'] for i in mappings['pubmed_ids']])
  extra = {
    'urn'          : mappings['urn'],
    'publish_date' : mappings['publish_date'],
    'refseq'       : refseq,
    'pubmed'       : pubmed,
  }

  out = []
  index = 0
  for row in scores:
    # Skip special HGVSp
    if row['hgvs_pro'] in ('_sy', '_wt'):
      continue

    # Skip missing values
    if row['score'] == "NA" or row['score'] is None:
      continue
    score = float(row['score'])

    # Iterate over mappings to find next non-missing value
    mapping, index = get_next_mapping(mappings['mapped_scores'], index)
    score_mappings = float(mapping['score'])

    # Map available information
    if isclose(score, score_mappings):
      row = round_float_columns(row)
      mapped_info = mapping['post_mapped']
      if mapped_info['type'] == "Haplotype":
        for member in mapped_info['members']:
          out += map_variant_to_MaveDB_scores(matches, member, row, extra)
      else:
        out += map_variant_to_MaveDB_scores(matches, mapped_info, row, extra)
      index += 1
    else:
      warnings.warn("score mismatch for " + row['accession'] + "; " + row['hgvs_pro'])
      continue
  return out

def write_variant_mapping (f, map):
  """Write mapping between MaveDB scores and associated variants to output file"""

  with open(f, 'w') as csvfile:
    header = list(map[0].keys())
    header = [h for h in header if h not in ['HGVSp', 'index']]
    writer = csv.DictWriter(csvfile, delimiter="\t", fieldnames=header,
                            extrasaction='ignore')
    # prepare new header
    new_header = [h.replace('hgvs_', '') for h in header]
    header = OrderedDict(zip(header, new_header))

    writer.writerow(header)
    writer.writerows(map)
  return True

# download MaveDB scores
urn         = f"urn:mavedb:{args.urn}"
url         = f"https://api.mavedb.org/api/v1/score-sets/{urn}/scores"
scores_file = f"{args.urn}_scores.txt"
if not os.path.isfile(scores_file):
  print("Downloading MaveDB scores...", flush=True)
  urllib.request.urlretrieve(url, scores_file)

# load MaveDB mappings, scores and HGVSP to variant matches
print("Loading MaveDB data...", flush=True)
scores     = load_scores(scores_file)
mappings   = json.load(open(args.mappings))

if args.vr is not None:
  hgvsp2vars = load_vr_output(args.vr)
else:
  hgvsp2vars = None

# create output file with variant location and respective scores
print("Preparing mappings between variants and MaveDB scores...", flush=True)
map = map_scores_to_variants(scores, mappings, hgvsp2vars)
write_variant_mapping(args.output, map)

# clean up
os.remove(scores_file)
