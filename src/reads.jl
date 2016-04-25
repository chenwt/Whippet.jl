
function make_fqparser( filename )
   if isgzipped( filename )
      fopen = open( filename, "r" ) 
      to_open = ZlibInflateInputStream( fopen, reset_on_end=true )
   else
      to_open = filename
   end 
   open( to_open, FASTQ )
end

function read_chunk!( chunk, parser )
   i = 1
   while i <= length(chunk) && read!( parser, chunk[i] )
      i += 1
   end
   while i <= length(chunk)
      pop!(chunk) # clean up if we are at the end
   end
   parser
end

function allocate_chunk( parser; size=100000 )
  chunk = Vector{eltype(parser)}( size )
  for i in 1:length(chunk)
     chunk[i] = eltype(parser)()
  end
  chunk
end

allocate_rref( size=250000; rreftype=RemoteRef{Channel{Any}} ) = Vector{rreftype}( size )

function resize_rref!( rref, subsize )
   @assert subsize <= length(rref)
   while subsize <= length(rref)
      pop!(rref) # clean up if we are at the end
   end
end

function sendto(p::Int, nm, val)
   ref = @spawnat(p, eval(Main, Expr(:(=), nm, val)))
end

macro sendto(p, nm, val)
   return :( sendto($p, $nm, $val) )
end

macro broadcast(nm, val)
   quote
      @sync for p in workers()
         @async sendto(p, $nm, $val)
      end
   end
end

# Use this function for true positive rates in the accuracy branch.
function ismappedcorrectly( read::SeqRecord, avec::Vector{SGAlignment}, lib::GraphLib )
   ord    = sortperm( avec, by=score )
   best   = avec[ ord[end] ]
   gene   = best.path[1].gene
   spl    = split( read.name, '/' )[end] |> x->split( x, ';' )
   @assert( length(spl) == 3, "ERROR: Incorrect format for simulated read name, $(spl)!" )
   nodes  = split( spl[1], '_' )[end] |> x->split( x, '-' )
   offset = split( spl[2], ':' )[end] |> x->split( x, '-' )
   @assert( length(offset) == 2, "ERROR: Incorrect format for simulated read name, $(read.name)!" )
   off = parse(Int, offset[1]), parse(Int, offset[2])
   used  = 0
   # compare simulated path with best.path
   len = off[2] - off[1]
   has_started = false
   path = IntSet()
   # get path from nodestr, store into IntSet
   for nstr in nodes
      n = parse(Int, nstr)
      if used <= off[1] < used+lib.graphs[gene].nodelen[n]
         len -= used+lib.graphs[gene].nodelen[n] - off[1]
         has_started = true
         push!(path, n)
      elseif has_started
         if len > 0
            push!(path, n)
            len -= lib.graphs[gene].nodelen[n]
         else
            break
         end
      end
      used += lib.graphs[gene].nodelen[n]
   end

   # now test if they are equivalent
   partial = true
   complete = true
   if best.path[1].node == first(path)
      shift!(path)
      for i in 2:length(best.path)
         if best.path[i].node != first(path)
            complete = false
            break
         end
         shift!(path)
      end
   else
      partial = false
      complete = false
   end
   partial,complete
end

process_reads!( parser, param::AlignParam, lib::GraphLib,
                quant::GraphLibQuant, multi::Vector{Multimap}; 
                bufsize=50, sam=false, simul=false) = _process_reads!( parser, param, lib, quant,
                                                      multi, bufsize=bufsize, sam=sam, simul=simul )

function _process_reads!( parser, param::AlignParam, lib::GraphLib, quant::GraphLibQuant, 
                         multi::Vector{Multimap}; bufsize=50, sam=false, simul=false )
  
   const reads  = allocate_chunk( parser, size=bufsize )
   mean_readlen = 0.0
   total        = 0
   mapped       = 0
   correct_part = 0
   correct_full = 0
   if sam
      stdbuf = BufferedOutputStream( STDOUT )
      write_sam_header( stdbuf, lib )
   end
   while length(reads) > 0
      read_chunk!( reads, parser )
      total += length(reads)
      for i in 1:length(reads)
         align = ungapped_align( param, lib, reads[i] )
         if !isnull( align )
            if length( align.value ) > 1
               push!( multi, Multimap( align.value ) )
            else
               count!( quant, align.value[1] )
               sam && write_sam( stdbuf, reads[i], align.value[1], lib )
            end
            if simul
               part,full = ismappedcorrectly( reads[i], align.value, lib )
               correct_part += part ? 1 : 0
               correct_full += full ? 1 : 0
            end
            mapped += 1
            @fastmath mean_readlen += (length(reads[i].seq) - mean_readlen) / mapped
         end
      end
   end # end while
   if sam
      close(stdbuf)
   end
   mapped,correct_part,correct_full,total,mean_readlen
end

# paired end version
process_paired_reads!( fwd_parser, rev_parser, param::AlignParam, lib::GraphLib,
                quant::GraphLibQuant, multi::Vector{Multimap}; 
                bufsize=50, sam=false) = _process_paired_reads!( fwd_parser, rev_parser, param, lib, quant,
                                                                 multi, bufsize=bufsize, sam=sam )

function _process_paired_reads!( fwd_parser, rev_parser, param::AlignParam, lib::GraphLib, quant::GraphLibQuant,
                                 multi::Vector{Multimap}; bufsize=50, sam=false )

   const fwd_reads  = allocate_chunk( fwd_parser, size=bufsize )
   const rev_reads  = allocate_chunk( rev_parser, size=bufsize )
   mean_readlen = 0.0
   total        = 0
   mapped       = 0
   if sam
      stdbuf = BufferedOutputStream( STDOUT )
      write_sam_header( stdbuf, lib )
   end
   while length(fwd_reads) > 0 && length(rev_reads) > 0
      read_chunk!( fwd_reads, fwd_parser )
      read_chunk!( rev_reads, rev_parser )
      total += length(fwd_reads)
      for i in 1:length(fwd_reads)
         fwd_aln,rev_aln = ungapped_align( param, lib, fwd_reads[i], rev_reads[i] )
         if !isnull( fwd_aln ) && !isnull( rev_aln )
            if length( fwd_aln.value ) > 1
               push!( multi, Multimap( fwd_aln.value ) )
               push!( multi, Multimap( rev_aln.value ) )
            else
               count!( quant, fwd_aln.value[1], rev_aln.value[1] )
               sam && write_sam( stdbuf, fwd_reads[i], fwd_aln.value[1], lib, paired=true, fwd_mate=true )
               sam && write_sam( stdbuf, rev_reads[i], rev_aln.value[1], lib, paired=true, fwd_mate=false )
            end
            mapped += 1
            @fastmath mean_readlen += (length(fwd_reads[i].seq) - mean_readlen) / mapped
         end
      end
   end # end while
   if sam
      close(stdbuf)
   end
   mapped,total,mean_readlen
end
