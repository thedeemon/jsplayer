package ;
import js.Lib;
import openfl.events.Event;
import openfl.events.ProgressEvent;
import openfl.net.URLRequest;
import openfl.utils.ByteArray;
import openfl.utils.Endian;
import haxe.Timer;
import InputBuffer;
import AudioTrack;
import PostStream;
import VideoData;
import Int64;
import openfl.external.ExternalInterface;
import List;
import js.html.Uint8Array;

enum FrameInfo { frame_ready(frm : CompressedFrame); frame_notready; frame_loading;  }

enum ReadStatus { more_data; done; go_on; }

enum PossibleChange { change(pos : Int); unknown(pos : Int); }

class DataLoader 
{	
#if indexed
	var stream : PostStream;
#else
	var stream : GetStream;
#end
	var frames : Array<CompressedFrame>;
	var reader : Void -> ReadStatus;
	var video_info_cb : VideoInfo -> Void;	
	var buffer : InputBuffer;
	var sound_buffer : InputBuffer;
	var avi_parser : AVIParser;		
	var mp3_parser : MP3Parser;
	var indexes : Array<Index>;
	var reading_start_position : Int64;	
	var avi_parsing_pos : Int; //number of next frame to be parsed
	var nframes : Int;
	var stop_loading : Bool;
	var riff_size : UInt;
	var last_logged_sz : Float;

	public var audio_track(default, null) : AudioTrack;
	public var decoder : IVideoCodec; //set by manager when codec is created
	
	public function new() 
	{
		frames = new Array<CompressedFrame>();
		buffer = new InputBuffer();
		sound_buffer = new InputBuffer();
		audio_track = new AudioTrack();
		avi_parsing_pos = 0;		
		nframes = 0;		
		stop_loading = false;
		riff_size = 0xFFFFFFFF;
		last_logged_sz = 0;
		//reader = read_header;
	}
	
	public function StopAndClean():Void
	{
		Logging.MLog("DL.StopAndClean");
		frames = null; reader = null; video_info_cb = null; buffer = null; sound_buffer = null;
		avi_parser = null; mp3_parser = null; indexes = null; stop_loading = true;
		audio_track.StopAndClean();
		audio_track = null;
		last_logged_sz = 0;
	}
	
	public function ShowBufLens() {
		Logging.MLog("DL: buf=" + buffer.Num() + " sound_buf=" + sound_buffer.Num());
	}
	
	public function Open(url: String, video_info_callback : VideoInfo -> Void):Void
	{
		#if indexed
		stream = new PostStream();
		#else		
		stream = new GetStream();
		#end
		var req = new URLRequest(url);
		video_info_cb = video_info_callback;
		stop_loading = false;
		//stream.endian = Endian.LITTLE_ENDIAN; 
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);		
		stream.load(req);		
	}
	
	public function GetFrame(num : UInt, callers:List<String>) : FrameInfo
	{
		if ( cast(num, Int) >= frames.length || frames[num] == null || frames[num].data == null) 
			return frame_notready;
		else return frame_ready(frames[num]);
	}
	
	public function GetFrameNotLoading(num : UInt) : FrameInfo
	{
		#if callstack
		return GetFrame(num, DataLoader.MkList("GetFrameNotLoading " + num));
		#else
		return GetFrame(num, null);
		#end
	}
	
	public function GetFrameChanges(num : UInt) : Null<Bool>
	{
		if (cast(num,Int) < frames.length) return frames[num].significant_changes;
		return null;
	}
	
	public function LoadedFramesEnd():Int
	{
		return frames.length;
	}
	
	public function LoadedFramesStart():Int
	{
		return 0;
	}
	
	public function GetNearestKeyframe(n:Int):Int
	{		
		if (frames == null || frames.length == 0) return 0;
		if (n >= frames.length) n = frames.length - 1;
		while ((frames[n]==null || !frames[n].key) && n > 0)
			n--;
		return n;		
	}
	
	public function GetNextKeyFrame(n:Int):Int
	{
		var len = frames.length;
		if (len == 0) return 0;
		if (n >= len) n = len - 1;
		while (n < len-1 && (frames[n]==null || !frames[n].key))
			n++;
		return n;				
	}
		
	function on_progress(e:ProgressEvent):Void
	{
		var n = stream.bytesAvailable;
		//js.Lib.debug();
		/*#if logging
		var details = "";
		var show = false;
		if (e != null) {
			details = " e.bytesLoaded=" + e.bytesLoaded + " e.bytesTotal=" + e.bytesTotal;		
			if (e.bytesLoaded < 20000 && e.bytesLoaded + 20000 >= e.bytesTotal)
				show = true;
			if (last_logged_sz + 500000 <= e.bytesLoaded) 
				show = true;							
		}
		if (show && n > 0)	{
			//Logging.MLog("DataLoader.on_progress: stream.bytesAvailable=" + n + details);
			last_logged_sz = e.bytesLoaded;
		}
		#end*/
		
		if (stop_loading) { 
			//Logging.MLog("on_progress: stop_loading is true, returning");
			return;
		}
		if (n > 0) {
			stream.endian = Endian.LITTLE_ENDIAN; 
			var chunk = new ByteArray();
			chunk.length = n;
			chunk.position = 0;
			chunk.endian = Endian.LITTLE_ENDIAN;
			stream.readBytes(chunk, 0, n);
			buffer.AddChunk(chunk);					
		}
		
		var status;
		do {
			if (reader == null) return;
			status = reader();
			if (status == done) reader = null;
		} while (status == go_on);		
		
		if (stop_loading) 
			avi_parser.active = false;
	}	
	
	function on_complete(e:Event):Void
	{
		DataLoader.JSLog("on_complete: " + e);
		on_progress(null);
		avi_parser.active = false;
	}
	
	public function ParseSound():Void //must be called by Worker when no work for video
	{
		mp3_parser.Parse();
	}

	public function AudioTimeLoaded(fps:Float):Float
	{
		if (mp3_parser.NoMoreSound() || !mp3_parser.started)
			return frames.length / fps;
		else
			return audio_track.time_loaded;
	}

	function start_reading():ReadStatus
	{
		reader = keep_reading;
		avi_parser.Start();		
		return go_on;
	}
	
	function keep_reading():ReadStatus
	{
		if (avi_parser.Go()) {
			if (Parser.chill) {
				Parser.chill = false;
				return go_on;
			}
			return more_data;
		}
		//trace("file read done, nframes=" + frames.length);
		mp3_parser.OnDataEnd();
		//Timer.delay(audio_track.show, 5000);
		return done;
	}	

 	public function SetOnLoadOperComplete(handler : Void->Void):Void
	{		
	}
	
	public function NotifyPlayerPosition(pos : Int):Void
	{		
	}
	
	public function FindPossibleChange(pos_from : Int):PossibleChange
	{
		for (i in pos_from ... frames.length)
			if (frames[i] != null) {
				var ch = frames[i].significant_changes;
				if (ch != null) {
					if (ch) return change(i);
				} else 
					return unknown(i);
			} else 
				return unknown(i);
				
		return frames.length > 0 ? change(frames.length - 1) : unknown(pos_from);
	}
	
	function on_video_info(vi : VideoInfo):Void
	{
		nframes = vi.nframes;
		riff_size = vi.riff_size;
		for (i in 0...nframes)
			frames.push(null);
		
		if (video_info_cb != null)
			video_info_cb(vi);
	}

	
	function on_indx_data(data : Indx_data):Void
	{		
		switch(data) {
			case super_index(sindx, ckid):
				//trace("super indx " + ckid); trace(sindx);
				if (ckid & 0xFF0000 != 0x640000) {
					//trace("not video stream"); 
					on_audio_indx(data);
					return;
				}
				indexes = new Array<Index>();
				var frame_num = 0;
				for (sie in sindx) {
					indexes.push( Index.FromSuper(sie, frame_num) );
					frame_num += sie.duration;
				}				
				
			case std_index(frms, ckid, offset):
				//trace("std indx " + ckid); trace(frms); 
				if (ckid & 0xFF0000 != 0x640000) {
					//trace("not video stream"); 
					on_audio_indx(data);
					return;
				}
				indexes = new Array<Index>();
				var x = new Index();
				x.base_offset = offset;
				x.first_frame = 0;
				x.last_frame = frms.length - 1;
				x.frames = frms;
				indexes.push(x);				
		}		
		on_index_loaded();
	}
	
	function on_audio_indx(data : Indx_data):Void 
	{		
	}

	function on_index_loaded():Void //either idx1 or indx loaded
	{		
	}
	
	//ix00 is suddenly read from stream, the data arg is chunk data without chunk header
	function on_ix_read(data : ByteArray, ix_chunk_pos : UInt):Void 
	{
		var buf = new InputBuffer();
		var hd = new ByteArray();
		hd.length = 8; //fake chunk header
		buf.AddChunk(hd);
		buf.AddChunk(data);		
		var ix_pos = reading_start_position.Add(ix_chunk_pos);
		parse_ix(buf, ix_pos);
	}
	
	function parse_ix(buf:InputBuffer, ix_pos : Int64):Bool //buf must include chunk header ('ix00', size)
	{
		if (buf.BytesAvailable(0) >= 32) {
			var nentries = buf.ReadInt(12);
			var ckid = buf.ReadInt(16);
			//trace("parsing ix, nentries=" + nentries);
			if (cast( buf.BytesAvailable(32), UInt) >= nentries * 8) { //all required loaded	
				//which ix we loaded?
				//if we got here it means there was super index already read
				var index = find_index(ckid, ix_pos);
				if (index == null) return false; //don't know where to put the data				
				var pos = 32;
				var off_low = buf.ReadInt(20);
				var off_hi = buf.ReadInt(24);
				var base_offset = new Int64(off_low, off_hi);
				var frames = new Array<StdIndexEntry>();
				var last_off:UInt = 0;
				for (i in 0...nentries) {
					var off = buf.ReadInt(pos);
					var size = buf.ReadInt(pos + 4);
					var e = new StdIndexEntry();
					if (off == 0) off = last_off;
					else last_off = off;
					e.off = off - 8; //point to chunk header, not data
					e.size = size & 0x7FFFFFFF;
					e.key = (size & 0x80000000) == 0;
					frames.push(e);
					//trace("frm " + i + " off=" + off + " sz=" + e.size + " key=" + e.key);
					pos += 8;
				}
				index.frames = frames;
				index.base_offset = base_offset;
				var n = indexes.indexOf(index);
				if (n >= 0) 
					update_keyframes_info(n);
				//trace("ix " + n + " parsed");
				return true;
			}
		} //if have some data
		return false;
	}
	
	function find_index(ckid : UInt, ix_pos : Int64) : Index
	{
		if (ckid & 0xFF0000 == 0x640000) { //video ix 
			for (i in 0...indexes.length)
				if (indexes[i].idx_offset.Eq(ix_pos)) {
					return indexes[i];
				}		
		} 
		return null;
	}

	function update_keyframes_info(ixnum:Int):Void
	{
		var x = indexes[ixnum];
		var last_off:UInt = 0;
		for (i in 0...x.frames.length)  {
			var num = x.first_frame + i;			
			if (frames[num] != null) {
				frames[num].key = x.frames[i].key;
				frames[num].ix = ixnum;
				//test
				/*if (frames[num].data != null && decoder != null) {
					var ikey = x.frames[i].key;
					var dkey = decoder.IsKeyFrame(frames[num].data);
					if (ikey != dkey)
						//trace("key mismatch num=" + num + " ikey="+ikey + " dkey=" + dkey + " ixnum=" + ixnum + " i=" + i);
				}*/
				if (x.frames[i].size == 0) {
					//test
					/*if (frames[num].data != null && frames[num].data.length != 0)
						//trace("null frame mismatch num=" + num + " ixnum=" + ixnum + " i=" + i);*/
					frames[num].data = new Uint8Array(0);
				}
			} else {
				var d:Uint8Array = x.frames[i].size == 0 ? new Uint8Array(0) : null;
				frames[num] = { key : x.frames[i].key, data : d, ix : ixnum, significant_changes : null};
			}
		}
	}
	
	public static inline function JSLog(msg:String):Void
	{		
		#if logging
		//if (ExternalInterface.available)
		//	ExternalInterface.call("playerLog", msg);
		//ELog(msg);
		trace(msg);
		#end
	}
	
	public static inline function ELog(msg:String, ?t0:Float):Float
	{
		var t:Float = Timer.stamp();
		#if logging		
		//if (Logging.extra) JSLog("t=" + t + ": " + (t0 == null ? msg : msg + " dt=" + (t-t0)));
		if (Logging.extra) 
			Logging.FastLog(msg, t0, t);
		#end		
		return t;
	}
	
	public static inline function MkList(s:String):List<String>
	{
		var a = new List<String>();
		a.add(s);
		return a;
	}
}