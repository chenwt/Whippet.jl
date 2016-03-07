#!/usr/bin/env julia
# Tim Sterne-Weiler 2015

using DataStructures
using IntervalTrees
using Bio.Seq
using FMIndexes
using IntArrays
using Libz

using ArgParse

const dir = abspath( splitdir(@__FILE__)[1] * "/../src" )

include("$dir/types.jl")
include("$dir/bio_nuc_safepatch.jl")
include("$dir/refflat.jl")
include("$dir/graph.jl")
include("$dir/edges.jl")
include("$dir/index.jl")

function parse_cmd()
  s = ArgParseSettings(version="Whippet v0.0.1-dev", add_version=true)

  @add_arg_table s begin
    "--kmer", "-k"
      help = "Kmer size to use for exon-exon junctions (default 9)"
      arg_type = Int
      default  = 9
    "--fasta"
      help = "File containg the genome in fasta, one entry per chromosome [.gz]"
      arg_type = ASCIIString
      required = true
    "--flat"
      help = "Gene annotation file in RefFlat format"
      arg_type = ASCIIString
      required = true
    "--index"
      help = "Output prefix for saving index 'dir/prefix' (default Whippet/index/graph)"
      arg_type = ASCIIString
      default = "$dir/../index/graph"
  end
  return parse_args(s)
end

function main()

   args = parse_cmd()

   println(STDERR, "Loading Refflat file...")
   flat = fixpath( args["flat"] )
   fh = open( flat , "r")
   if isgzipped( flat )
      fh = fh |> ZlibInflateInputStream
   end
   @time ref = load_refflat(fh)

   println(STDERR, "Indexing transcriptome...")
   @time graphome = fasta_to_index( fixpath( args["fasta"] ) , ref, kmer=args["kmer"] )

   println(STDERR, "Saving Annotations...")
   open("$(args["index"])_anno.jls", "w+") do fh
      @time serialize(fh, ref)
   end

   println(STDERR, "Saving splice graph index...")
   open("$(args["index"]).jls", "w+") do io
      @time serialize( io, graphome )
   end

end

main()