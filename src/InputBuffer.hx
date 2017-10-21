package ;

import openfl.utils.ByteArray;

class InputBuffer 
{
	var chunks : Array<ByteArray>;
	var total_size : UInt;
	var local_pos : UInt;
	var cur_chunk : UInt;
	var cur_chunk_start : UInt;
	var cur_chunk_end : UInt;
	var starts : Array<UInt>;
	var first_present_chunk : UInt;
	
	public function new() 
	{
		chunks = new Array<ByteArray>();
		total_size = 0;
		cur_chunk = 0; cur_chunk_start = 0; cur_chunk_end = 0;
		starts = new Array<UInt>();
		first_present_chunk = 0;
	}
	
	public function AddChunk(data : ByteArray):Void
	{
		starts.push(total_size);
		chunks.push(data);
		total_size += data.length;
	}
	
	public function BytesAvailable(position : UInt):Int
	{
		return total_size - position;
	}
	
	public function Clear():Void
	{
		starts = [];//.length = 0;
		chunks = [];// .length = 0;
		total_size = 0;
		first_present_chunk = 0;
	}
	
	public function ReadInt(position : UInt):UInt
	{		
		var pos : UInt;
		
		if (position >= cur_chunk_end || position < cur_chunk_start) {
			cur_chunk = FindChunk(position);
			cur_chunk_start = starts[cur_chunk];
			cur_chunk_end = cur_chunk_start + chunks[cur_chunk].length;
			pos = position - cur_chunk_start;					
		} else
			pos = position - cur_chunk_start;
			
		if (cur_chunk_end - position < 4) {
			if (Std.int(cur_chunk) < chunks.length - 1) {
				Join(cur_chunk);
				return ReadInt(position);
			} else {
				trace("ReadInt panic position=" + position);
				return 0;
			}
		}
		
		chunks[cur_chunk].position = pos;
		return chunks[cur_chunk].readUnsignedInt();
	}
	
	public function ReadBytes(position:UInt, dest:ByteArray, offset:Int, length:UInt):Void
	{
		var pos : UInt;
		
		if (position >= cur_chunk_end || position < cur_chunk_start) {
			cur_chunk = FindChunk(position);
			cur_chunk_start = starts[cur_chunk];
			cur_chunk_end = cur_chunk_start + chunks[cur_chunk].length;
			pos = position - cur_chunk_start;		
		} else
			pos = position - cur_chunk_start;
		
		chunks[cur_chunk].position = pos;
		if (cur_chunk_end - position >= length) {			
			chunks[cur_chunk].readBytes(dest, offset, length);
		} else {
			var n = cur_chunk_end - position;
			chunks[cur_chunk].readBytes(dest, offset, n);
			ReadBytes(position + n, dest, offset + n, length - n);
		}
	}
	
	public function ReadIntBigEndian(position : UInt):UInt
	{
		var x = ReadInt(position);
		return (x >> 24) + ((x >> 8) & 0xFF00) + ((x << 8) & 0xFF0000) + ((x & 0xFF) << 24);
	}
	
	function FindChunk(position : UInt):UInt
	{
		var lo:UInt = first_present_chunk;
		var hi = cast( chunks.length, UInt );
		while (lo < hi) {
			var mid = (hi + lo) >> 1;
			if (position >= starts[mid] && position < starts[mid] + chunks[mid].length)
				return mid;
			if (position < starts[mid])
				hi = mid;
			else
				lo = mid + 1;
		}
		return 0;
	}	
	
	function Join(i : Int):Void //join chunks i and i+1
	{
		var off = chunks[i].length;
		chunks[i].length = off + chunks[i + 1].length;
		chunks[i + 1].position = 0;
		chunks[i].position = off;
		chunks[i].writeBytes(chunks[i + 1], 0, chunks[i + 1].length);
		cur_chunk_end += chunks[i + 1].length;
		for (j in (i + 1) ... (chunks.length - 1)) {
			chunks[j] = chunks[j + 1];
			starts[j] = starts[j + 1];
		}
		chunks.pop();	
		starts.pop();
	}
	
	public function DontNeedUpTo(position : UInt):Void //data before position will not be needed anymore
	{
		return;
		var k = 0;
		if (position >= cur_chunk_start && position < cur_chunk_end) 
			k = cur_chunk;
		else
			k = FindChunk(position);
		for (i in 0...k)
			chunks[i] = null;
		first_present_chunk = k;
	}
}