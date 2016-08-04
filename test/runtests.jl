if VERSION >= v"0.5-"
   using Base.Test
else        
   using BaseTestNext 
   const Test = BaseTestNext            
end

using DataStructures
using BufferedStreams
using Bio.Seq
using FMIndexes
using IntArrays
using IntervalTrees
using Libz
using Distributions

include("../src/types.jl")
include("../src/timer.jl")
include("../src/bio_nuc_safepatch.jl")
include("../src/refset.jl")
include("../src/graph.jl")
include("../src/edges.jl")
include("../src/index.jl")
include("../src/align.jl")
include("../src/quant.jl")
include("../src/reads.jl")
include("../src/paired.jl")
include("../src/events.jl")
include("../src/io.jl")
include("../src/diff.jl")

@testset "Bio.Seq Patch" begin
   @test typeof(sg"GATGCA") == NucleotideSequence{SGNucleotide}
   @test reverse_complement(sg"GATGCA") == sg"TGCATC"
   @test reverse_complement(sg"LRS")    == sg"SRL" 
   fullset = sg"ACGTNLRS"
   fullarr = [ SG_A, SG_C, SG_G, SG_T, SG_N, SG_L, SG_R, SG_S ]
   for n in 0:(length(fullset)-1)
      i = n+1
      @test fullset[i] == fullarr[i]
      @test convert(UInt8, fullset[i]) == UInt8(n)
      @test convert(SGNucleotide, UInt8(n)) == fullset[i]
   end
   @test sg"AT" * sg"TA" == sg"ATTA"
end
@testset "Splice Graphs" begin
   gtf = IOBuffer("# gtf file test
chr0\tTEST\texon\t6\t20\t.\t+\t.\tgene_id \"one\"; transcript_id \"def\";
chr0\tTEST\texon\t31\t40\t.\t+\t.\tgene_id \"one\"; transcript_id \"def\";
chr0\tTEST\texon\t54\t62\t.\t+\t.\tgene_id \"one\"; transcript_id \"def\";
chr0\tTEST\texon\t76\t85\t.\t+\t.\tgene_id \"one\"; transcript_id \"def\";
chr0\tTEST\texon\t6\t40\t.\t+\t.\tgene_id \"one\"; transcript_id \"int1_alt3\";
chr0\tTEST\texon\t51\t62\t.\t+\t.\tgene_id \"one\"; transcript_id \"int1_alt3\";
chr0\tTEST\texon\t76\t85\t.\t+\t.\tgene_id \"one\"; transcript_id \"int1_alt3\";
chr0\tTEST\texon\t6\t20\t.\t+\t.\tgene_id \"one\"; transcript_id \"apa_alt5\";
chr0\tTEST\texon\t31\t40\t.\t+\t.\tgene_id \"one\"; transcript_id \"apa_alt5\";
chr0\tTEST\texon\t54\t65\t.\t+\t.\tgene_id \"one\"; transcript_id \"apa_alt5\";
chr0\tTEST\texon\t76\t90\t.\t+\t.\tgene_id \"one\"; transcript_id \"apa_alt5\";
chr0\tTEST\texon\t11\t20\t.\t+\t.\tgene_id \"single\"; transcript_id \"ex1_single\";
chr0\tTEST\texon\t11\t20\t.\t-\t.\tgene_id \"single_rev\"; transcript_id \"single_rev\";
chr0\tTEST\texon\t11\t20\t.\t-\t.\tgene_id \"kissing\"; transcript_id \"def_kiss\";
chr0\tTEST\texon\t21\t30\t.\t-\t.\tgene_id \"kissing\"; transcript_id \"def_kiss\";
chr0\tTEST\texon\t11\t30\t.\t-\t.\tgene_id \"kissing\"; transcript_id \"ret_kiss\";
")

   flat = IOBuffer("# refflat file test (gtfToGenePred -genePredExt test.gtf test.flat)
def\tchr0\t+\t5\t85\t85\t85\t4\t5,30,53,75,\t20,40,62,85,\t0\tone\tnone\tnone\t-1,-1,-1,-1,
int1_alt3\tchr0\t+\t5\t85\t85\t85\t3\t5,50,75,\t40,62,85,\t0\tone\tnone\tnone\t-1,-1,-1,
apa_alt5\tchr0\t+\t5\t90\t90\t90\t4\t5,30,53,75,\t20,40,65,90,\t0\tone\tnone\tnone\t-1,-1,-1,-1,
ex1_single\tchr0\t+\t10\t20\t10\t20\t1\t10,\t20,\t0\tsingle\tnone\tnone\t-1,
")

   gtfref  = load_gtf( gtf )
   flatref = load_refflat( flat )

   @testset "Gene Annotation" begin

      for gene in keys(flatref)
         @test gtfref[gene].don    == flatref[gene].don
         @test gtfref[gene].acc    == flatref[gene].acc
         @test gtfref[gene].txst   == flatref[gene].txst
         @test gtfref[gene].txen   == flatref[gene].txen
         @test gtfref[gene].length == flatref[gene].length
         for i in 1:length(flatref[gene].reftx)
            flattx = flatref[gene].reftx[i]
            gtftx  = gtfref[gene].reftx[i]
            @test flattx.don == gtftx.don
            @test flattx.acc == gtftx.acc
         end
      end

   end

                              # fwd     rev
   buffer1   = sg"AAAAA"      # 1-5     96-100
   utr5      = sg"TTATT"      # 6-10    91-95
   exon1     = sg"GCGGATTACA" # 11-20   81-90
   int1      = sg"TTTTTTTTTT" # 21-30   71-80
   exon2     = sg"GCATTAGAAG" # 31-40   61-70
   int2      = sg"GGGGGGGGGG" # 41-50   51-60
   exon3alt3 = sg"CCT"        # 51-53   48-50
   exon3def  = sg"CTATGCTAG"  # 54-62   39-47
   exon3alt5 = sg"TTC"        # 63-65   36-38
   int3      = sg"CCCCCCCCCC" # 66-75   26-35
   exon4     = sg"TTAGACAAGA" # 76-85   16-25
   apa       = sg"AATAA"      # 86-90   11-15
   buffer2   = sg"AAAAAAAAAA" # 91-100  1-10

   fwd = buffer1 * utr5 * exon1 * int1 * 
         exon2 * int2 * 
         exon3alt3 * exon3def * exon3alt5 * int3 * 
         exon4 * apa * buffer2
   rev = reverse_complement(fwd)

   genome = fwd * rev

   graphseq_one = sg"SL" * utr5 * exon1 * sg"LL" * 
               int1 * sg"RR" *
               exon2 * sg"LR" * 
               exon3alt3 * sg"RR" * 
               exon3def * sg"LL" * 
               exon3alt5 * sg"LR" *
               exon4 * sg"RS" * 
               apa * sg"RS"

   graphseq_sin = sg"SLGCGGATTACARS"
   graphseq_kis = sg"SLAAAAAAAAAALLRRTGTAATCCGCRS"

   graph_one = SpliceGraph( gtfref["one"], genome )
   graph_sin = SpliceGraph( gtfref["single"], genome )
   graph_rev = SpliceGraph( gtfref["single_rev"], genome)
   graph_kis = SpliceGraph( gtfref["kissing"], genome )

   @testset "Graph Building" begin
      @test graph_one.seq == graphseq_one
      @test graph_sin.seq == graphseq_sin
      @test graph_kis.seq == graphseq_kis

      @test length(graph_one.annopath) == length(gtfref["one"].reftx)
      @test graph_one.annopath[1] == IntSet([1,3,5,7]) #def
      @test graph_one.annopath[2] == IntSet([1,2,3,4,5,7]) # int1_alt3
      @test graph_one.annopath[3] == IntSet([1,3,5,6,7,8]) # apa_alt5
   end

   kmer_size = 2 # good test size

   # Build Index (from index.jl)
   xcript  = sg""
   xoffset = Vector{UInt64}()
   xgenes  = Vector{GeneName}()
   xinfo   = Vector{GeneInfo}()
   xgraph  = Vector{SpliceGraph}()

   runoffset = 0

   for g in keys(gtfref)
      curgraph = SpliceGraph( gtfref[g], genome )
      xcript  *= curgraph.seq
      push!(xgraph, curgraph)
      push!(xgenes, g)
      push!(xinfo, gtfref[g].info )
      push!(xoffset, runoffset)
      runoffset += length(curgraph.seq)   
   end

   fm = FMIndex(threebit_enc(xcript), 8, r=1, program=:SuffixArrays, mmap=true)

   edges = build_edges( xgraph, kmer_size )

   lib = GraphLib( xoffset, xgenes, xinfo, xgraph, edges, fm, true, kmer_size )

   @testset "Kmer Edges" begin
      left  = [sg"CA", sg"AG", sg"AG", sg"TC", sg"AA"]
      right = [sg"GC", sg"CC", sg"CT", sg"TT", sg"TG"]
      lkmer = map( x->kmer_index(SGKmer(x)), left )
      rkmer = map( x->kmer_index(SGKmer(x)), right )
      for i in 1:4^kmer_size
         if i in lkmer
            @test isdefined(edges.left, i)
            @test typeof(edges.left[i][1]) == SGNode
            @test issorted(edges.left[i])
         else
            @test !isdefined(edges.left, i)
         end
         if i in rkmer
            @test isdefined(edges.right, i)
            @test typeof(edges.right[i][1]) == SGNode
            @test issorted(edges.right[i])
         else
            @test !isdefined(edges.right, i)
         end
      end
   end

   @testset "Alignment" begin
            
   end
   
end
