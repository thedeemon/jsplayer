package ;
import openfl.utils.ByteArray;
import Parser;
import InputBuffer;
import DataLoader;
import openfl.utils.Endian;
import Int64;
import VideoData;

using ParserUtils;

class AVIParser extends ParserUser
{
    var avi : Parser;
    var add_frame : ByteArray -> Void;
    var add_sound : ByteArray -> Void;
    var video_info_cb : VideoInfo -> Void;
    var indx_data_cb : Indx_data -> Void;
    var ix_data_cb : ByteArray -> UInt -> Void;
    var video_info : VideoInfo;
    public var active : Bool;
    var avi_part : Parser;

    public function new(frame_data_handler : ByteArray -> Void, on_video_info : VideoInfo -> Void,
                        sound_data_handler : ByteArray -> Void,
                        ?indx_data_handler : Indx_data -> Void, ?ix_handler : ByteArray -> UInt -> Void)
    {
        super();
        add_frame = frame_data_handler;
        add_sound = sound_data_handler;
        video_info_cb = on_video_info;
        indx_data_cb = indx_data_handler;
        ix_data_cb = ix_handler;
        active = false;
    }

    public function SetFrameHandler(frame_data_handler : ByteArray -> Void):Void
    {
        add_frame = frame_data_handler;
    }

    function got_avih(hd : ByteArray) : Void
    {
        hd.position = 0;
        hd.endian = Endian.LITTLE_ENDIAN;
        var microsec = hd.readInt();
        var maxbytespersec = hd.readInt();
        var padgran = hd.readInt();
        var flags = hd.readInt();
        var totalframes = hd.readInt();
        var initialframes = hd.readInt();
        var nstreams = hd.readInt();
        var suggbuffsize = hd.readInt();
        var width = hd.readInt();
        var height = hd.readInt();
        /*trace(" microsec=" + microsec + " maxbytespersec=" + maxbytespersec + " padgran=" +padgran +
            " flags=" + flags + " totalframes=" + totalframes + " initialframes=" + initialframes + " nstreams=" + nstreams
            + " suggbuffsize=" +suggbuffsize + " width=" +width + " height=" +height);*/
        if (microsec == 0) microsec = 66666;
        video_info = { X:width, Y:height, bpp:32, fps:1000000 / microsec, nframes:totalframes,
                        codec:codec_screenpressor, palette:null, riff_size: GetVar("file_size") };
    }

    function got_vstream_format(blob : ByteArray):Void
    {
        video_info.nframes = GetVar("nframes");
        blob.position = 14;
        var bits = blob.readUnsignedShort();
        video_info.bpp = bits;
        var fourcc = GetVar("fourcc");
        if (fourcc == 0)
            fourcc = blob.readInt();
        video_info.riff_size = GetVar("file_size");
        //trace("fourcc=" + fourcc);
#if msvc
        if (fourcc==Hex("MSVC") || fourcc==Hex("msvc") || fourcc==Hex("CRAM") || fourcc==0)
            video_info.codec = bits == 8 ? codec_msvc8 : codec_msvc16;
#end
        if (bits == 8 && blob.length > 40) {
            blob.position = 40;
            var pal = new ByteArray();
            pal.length = blob.bytesAvailable;
            blob.readBytes(pal);
            video_info.palette = pal;
        }
        if (video_info_cb != null)
            video_info_cb(video_info);
    }

    function got_indx(data : ByteArray):Void
    {
        if (indx_data_cb == null) return;
        data.position = 0;
        data.endian = Endian.LITTLE_ENDIAN;
        var longs_per_entry = data.readUnsignedShort();
        data.readByte(); //index subtype
        var index_type =  data.readUnsignedByte();
        var entries_used = data.readUnsignedInt();
        var ckid = data.readUnsignedInt();

        if (longs_per_entry == 4) {
            data.position += 12;
            //trace("superindex");
            var index : Array<SuperIndexEntry> = new Array<SuperIndexEntry>();
            for (i in 0...entries_used)
                index.push(new SuperIndexEntry(data));
            indx_data_cb( super_index(index, ckid) );
        } else
        if (longs_per_entry == 2) {
            //trace("std index");
            var offset = Int64.Read(data);
            data.position += 4;
            var index : Array<StdIndexEntry> = new Array<StdIndexEntry>();
            for (i in 0...entries_used)
                index.push(new StdIndexEntry(data));
            indx_data_cb( std_index(index, ckid, offset) );
        } else {
            //trace("bad indx!");
        }
    }

    function got_ix(data : ByteArray):Void
    {
        if (ix_data_cb != null) ix_data_cb(data, GetVar("ix_size_pos") - 4);
    }

    function on_add_frame(arr:ByteArray):Void
    {
        if (add_frame != null)    add_frame(arr);
    }

    function got_astream_header(data:ByteArray):Void //not including first 4 bytes - 'auds'
    {

    }

    function got_astream_format(data:ByteArray):Void
    {

    }

    public function Start():Void
    {
        var frame_chunk = once(seq([Const("00dc").or(Const("00db")), Var("frame_size"), Blob("frame_size".pad(), on_add_frame)]));
        var sound_chunk = once(seq([Const("01wb"), Var("sound_size"), Blob("sound_size".pad(), add_sound_chunk)]));
        var ix_chunk = seq([Const("ix00").or(Const("ix01")), VarP("ix_size"), Blob("ix_size".pad(), got_ix)]);
        var data_chunk = frame_chunk.or(sound_chunk).or(ix_chunk);
        var other_chunk = seq([SomeInt, Var("chunk_size"), Blob("chunk_size".pad())]);
        var rec_chunk = data_chunk.or(other_chunk);
        var list_rec = seq([Const("LIST"), Var("rec_size"), Const("rec "), rec_chunk.until("rec_size".minus(4))]);
        var sub_chunk = data_chunk.or(list_rec).or(other_chunk);
        var list_movi = seq([Const("LIST"), VarP("movi_size"), Const("movi"), sub_chunk.until("movi_size".minus(4))]);
        var vstream_format = seq([Const("strf"), Var("strf_size"), Blob("strf_size".pad(), got_vstream_format)]);
        var vstream_header = seq([Const("strh"), Var("strh_size"), Const("vids"), Var("fourcc"),
                                    Blob(24), Var("nframes"), Blob("strh_size".minus(36))]);

        var indx_chunk = seq([Const("indx"), Var("indx_size"), Blob("indx_size".pad(), got_indx)]);

        var astream_header = seq([Const("strh"), Var("strh_size"), Const("auds"), Blob("strh_size".minus(4), got_astream_header)]);
        var astream_format = seq([Const("strf"), Var("strf_size"), Blob("strf_size".pad(), got_astream_format)]);

        var list_strl = seq([Const("LIST"), Var("strl_size"), Const("strl"),
                            seq([vstream_header, vstream_format])
                            .or(seq([astream_header, astream_format]))
                            .or(indx_chunk).or(other_chunk).until("strl_size".minus(4))]);
        var list_hdrl = seq([Const("LIST"), Var("hdrl_size"), Const("hdrl"),
                                Const("avih"), Var("avih_size"), Blob("avih_size".pad(), got_avih),
                                list_strl.or(other_chunk).until("hdrl_size".minus("avih_size".plus(12))) ]);

        var contents = list_hdrl.or(list_movi).or(other_chunk).until("file_size".minus(4));
        avi = seq([Const("RIFF"), Var("file_size"), Const("AVI "), contents]);

        var me = this;

        avi.success = function(pos:Int) : Void { /*trace("AVI parser success at " + pos);*/ Parser.current = null; me.active = false; }
        avi.fail = function():Void { trace("AVI parser failed"); Parser.current = null; me.active = false; }

        avi_part = sub_chunk.until( function():UInt { return 0x7FFFFFFF; } );
        avi_part.success = function(pos:Int) : Void { /*trace("AVI parser success at " + pos);*/ Parser.current = null; me.active = false; }
        avi_part.fail = function():Void { trace("AVI parser failed"); Parser.current = null; me.active = false; }

        active = true;
        avi.parse(0);
    }

    public function Go():Bool
    {
        if (Parser.current != null) {
            Parser.current();
            return true;
        }
        //trace("go false");
        return false;
    }

    function add_sound_chunk(chunk : ByteArray):Void
    {
        chunk.length = GetVar("sound_size");
        add_sound(chunk);
    }

    public function StartFromMiddle():Void
    {
        //trace("avi_part.parse");
        active = true;
        avi_part.parse(0);
    }
}
