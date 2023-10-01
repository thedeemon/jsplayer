package ;
import Int64;
import openfl.utils.ByteArray;
import js.html.Uint8Array;

class SuperIndexEntry {
    public var off : Int64;
    public var size : UInt;
    public var duration : UInt;

    public function new(data : ByteArray)
    {
        off = Int64.Read(data);
        size = data.readUnsignedInt();
        duration = data.readUnsignedInt();
        //trace("super index entry: off=" + off_low + " sz=" + size + " dur=" + duration);
    }

    public function toString():String
    {
        return "{SupIndEnt off=" + off + " sz=" + size + " dur=" + duration + "}";
    }
}

class StdIndexEntry {
    public var off : UInt;
    public var size : UInt;
    public var key : Bool;

    public function new(?data : ByteArray)
    {
        if (data != null) {
            off = data.readUnsignedInt() - 8; //point to chunk header, not data
            size = data.readUnsignedInt();
            key = (size & 0x80000000) == 0;
            size = size & 0x7FFFFFFF;
        }
    }
}

class Index
{
    public var first_frame : Int;
    public var last_frame : Int;
    public var base_offset : Int64; //add to frames offsets
    public var idx_offset : Int64;  //where index is
    public var frames : Array<StdIndexEntry>;
    public var size_in_bytes : UInt; //of index

    public function new()    {}

    public static function FromSuper(entry : SuperIndexEntry, start_frame : Int):Index
    {
        var x = new Index();
        x.first_frame = start_frame;
        x.last_frame = start_frame + entry.duration - 1;
        x.idx_offset = entry.off;
        x.size_in_bytes = entry.size;
        return x;
    }
}

enum Indx_data {
    super_index(index : Array<SuperIndexEntry>, ckid : UInt);
    std_index(index : Array<StdIndexEntry>, ckid : UInt, offset : Int64);
}

typedef CompressedFrame = {
    var key : Bool;
    var data : Uint8Array;
    var ix : Int; //index num
    var significant_changes : Null<Bool>;
}

enum CodecType {
    codec_screenpressor;
#if msvc
    codec_msvc16; codec_msvc8;
#end
}

typedef VideoInfo =  {
    var X : Int;
    var Y : Int;
    var bpp : Int;
    var fps : Float;
    var nframes : Int;
    var codec : CodecType;
    var palette : ByteArray;
    var riff_size : UInt;
}
