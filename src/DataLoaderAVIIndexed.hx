package ;
import js.Lib;
import openfl.events.Event;
import openfl.events.ProgressEvent;
import openfl.events.SecurityErrorEvent;
import openfl.events.HTTPStatusEvent;
import openfl.utils.ByteArray;
import openfl.utils.Endian;
import openfl.net.URLRequest;
import haxe.Timer;
import PostStream;
import Parser;
import InputBuffer;
import DataLoader;
import VideoData;
import AVIParser;
import List;
import StringBuf;
import js.html.Uint8Array;

class DataLoaderAVIIndexed extends DataLoader
{
	var idx_stream : PostStream;
	var req : URLRequest;
	var idx_buffer : InputBuffer;
	var idx_stream_start_pos : Int64; //position in file of requested part
	var pos_in_idx1_buf : UInt;
	var is_index_loaded : Bool;
	var first_frame_loaded : Int;
	var sum_size_loaded : Int;	
	var last_loaded_key_frame : Int; // set when breaking connection to know when to request next part
	var cur_last_key_frame : Int; // currently last loaded key frame, must be after FoI if we want to break connection
	var last_requested_frame : Int; 
	var foi_copy : Int; // copy of frame of interest from Manager, set in NotifyPlayerPos
	
	
	var requested_index_action : Void->Void;
	var requested_ix_action : Void->Void;
	var requested_frame_action : Void->Void;
	var requested_frame_num : Int;
	public static var storage_limit : Int = 50000000;
	static var zero64 : Int64 = new Int64(0, 0);
	
	var audio_indexes : Array<Index>;
	
	public function new() 
	{
		Logging.MLog("new DLAI");
		super();
		is_index_loaded = false;
		pos_in_idx1_buf = 0;				
		first_frame_loaded = 0;
		sum_size_loaded = 0; 
		last_loaded_key_frame = -1;
		requested_frame_num = -1;
		cur_last_key_frame = -1;
		foi_copy = 0;
	}
	
	override public function Open(url:String, video_info_callback:VideoInfo -> Void):Void 
	{		
		reader = start_reading;
		avi_parser = new AVIParser(on_first_frame, on_video_info, add_sound_chunk, on_indx_data, on_ix_read);
		Parser.ClearMem();
		Parser.input = buffer;			
		mp3_parser = new MP3Parser(sound_buffer, audio_track.AddFragment);
		//super.Open(url, video_info_callback);
		video_info_cb = video_info_callback;
		first_frame_loaded = 0;
		last_requested_frame = 0;
		reading_start_position = new Int64(0, 0);
		stop_loading = false;
		stream = new PostStream();
		
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);	
		stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error);
		stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, on_security_error);
		
		req = new URLRequest(url);		
		stream.LoadPart(req, "0", "999999");					
	}
	
	override public function StopAndClean()
	{
		Logging.MLog("DLAI.StopAndClean");
		if (stream!=null) {
			stream.StopAndClean();
			stream = null;
		}
		if (idx_stream != null) {
			if (idx_stream.connected)
				idx_stream.close();
			idx_stream = null;
		}
		super.StopAndClean();
		Parser.StopAndClean();
		idx_buffer = null;
		audio_indexes = null;
		requested_frame_action = null;
		requested_index_action = null;
		requested_ix_action = null;
	}
		
	override private function on_audio_indx(data:Indx_data):Void 
	{
		switch(data) {
			case super_index(sindx, ckid):				
				if (ckid & 0xFF0000 != 0x770000) {
					//trace("not audio stream"); 					
					return;
				}
				audio_indexes = new Array<Index>();
				var frame_num = 0;
				for (sie in sindx) {
					audio_indexes.push( Index.FromSuper(sie, frame_num) );
					frame_num += sie.duration;
				}				
				
			case std_index(frms, ckid, offset):				
				if (ckid & 0xFF0000 != 0x770000) {
					//trace("not audio stream"); 					
					return;
				}
				audio_indexes = new Array<Index>();
				var x = new Index();
				x.base_offset = offset;
				x.first_frame = 0;
				x.last_frame = frms.length - 1;
				x.frames = frms;
				audio_indexes.push(x);				
		}		
	}

	function on_first_frame(arr : ByteArray):Void
	{
		DataLoader.JSLog("DLAI.on_first_frame got first frame len=" + arr.length);
		avi_parser.SetFrameHandler(add_frame);
		add_frame(arr);		
		
		if (indexes == null) { //there was no indx in header
			var msz = avi_parser.GetVar("movi_size");
			var mpos = avi_parser.GetVar("movi_size_pos");
			var next_chunk_pos:UInt = mpos + msz + 4;
			DataLoader.JSLog("starting loading idx1");
			start_loading_idx1(next_chunk_pos);			
		} else {
			DataLoader.JSLog("indexes not null");			
			//if (!is_index_loaded && decoder.NeedsIndex()) 				
			start_loading_ixs();		
		}
	}	
	
	/*inline function is_key_frame(arr:ByteArray, pos:Int):Bool //just for testing
	{		
		var res = decoder.IsKeyFrame(arr);		
		if (res) trace("is key frame " + pos);
		return res;
	}*/
	
	function add_frame(arr : ByteArray):Void
	{	
		//Logging.MLog("DLAI.add_frame len=" + arr.length);
		if (arr.length != 0) { 
			//skip all zero-length frames created when ix was read
			while (frames[avi_parsing_pos] != null && frames[avi_parsing_pos].data != null && frames[avi_parsing_pos].data.length == 0) {
				//don't forget the callback
				if (avi_parsing_pos == requested_frame_num && requested_frame_action != null) {
					//DataLoader.ELog("add_frame calling requested_frame_action");
					requested_frame_action();
					//DataLoader.ELog("add_frame setting requested_frame_action = null");
					requested_frame_action = null;
				}				
				avi_parsing_pos++;
			}
		} //don't do this if zero-length frames are present in the stream and so passed here
		
		if (frames[avi_parsing_pos] != null) {
			frames[avi_parsing_pos].data = new Uint8Array( arr.toArrayBuffer() );
		} else {
			var u8a = new Uint8Array( arr.toArrayBuffer() );
			var keyfr = (avi_parsing_pos == 0 ? true : (decoder != null ? decoder.IsKeyFrame(u8a) : false));
			frames[avi_parsing_pos] = { key : keyfr, data : u8a, ix: -1, significant_changes : null };
		}
		if (avi_parsing_pos == requested_frame_num && requested_frame_action != null) {
			//DataLoader.ELog("add_frame calling requested_frame_action");
			requested_frame_action();
			//DataLoader.ELog("add_frame setting requested_frame_action=null");
			requested_frame_action = null;
		}
		sum_size_loaded += arr.length;
		if (frames[avi_parsing_pos].key) { 
			cur_last_key_frame = avi_parsing_pos;
			//Logging.MLog("DLAI.add_frame: key frame added at avi_parsing_pos=" + avi_parsing_pos);
		}
		
		var force_stop = false;
		if (avi_parsing_pos >= last_requested_frame && !(reading_start_position.Eq(zero64) && riff_size <= 999999)) {
			force_stop = true;			
			//DataLoader.JSLog("avi_parsing_pos >= last_requested_frame (" + avi_parsing_pos + " " +
			//	last_requested_frame + "), forcing stop");
		}
		
		avi_parsing_pos++;
		dont_load_too_much(force_stop);
	}
	
	function add_sound_chunk(chunk : ByteArray):Void
	{
		return; // to be fixed...
		//Logging.MLog("add_sound_chunk len=" + chunk.length);
		if (reading_start_position.Eq(zero64)) {
			sound_buffer.AddChunk(chunk);
			sum_size_loaded += chunk.length;
			dont_load_too_much(false);
		}
	}	
	
	function start_loading_idx1(pos : UInt):Void
	{
		//trace("start_loading_idx1 pos=" + pos);
		idx_stream = new PostStream();
		idx_stream.addEventListener(ProgressEvent.PROGRESS, on_idx1_data);
		idx_stream.addEventListener(Event.COMPLETE, on_idx1_data);		
		idx_stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error_idx);
		idx_buffer = new InputBuffer();
		pos_in_idx1_buf = 0;
		idx_stream_start_pos = new Int64(pos, 0);
		//trace("start_loading_idx1: load from "+ pos);
		idx_stream.LoadPart(req, Std.string(pos));	
	}
	
	function on_error(e:Event):Void
	{
		Logging.MLog("stream IO error: " + e);
		//trace("stream IO error: " + e);
	}
	
	function on_security_error(event : SecurityErrorEvent):Void {
        DataLoader.JSLog("stream.on_security_error: " + event);
    }
	
	function on_error_idx(e:Event):Void
	{
		Logging.MLog("idx_stream stream IO error: " + e);
		//trace("idx_stream IO error: " + e);
	}	
	
	function save_idx_chunk():Void
	{
		var n = idx_stream.bytesAvailable;
		if (n>0) {
			var chunk = new ByteArray();
			chunk.length = n;
			chunk.position = 0;
			chunk.endian = Endian.LITTLE_ENDIAN;
			idx_stream.readBytes(chunk, 0, n);
			idx_buffer.AddChunk(chunk);		
			Logging.MLog("saved idx chunk, total size: " + idx_buffer.BytesAvailable(0));
		}		
	}
	
	function on_idx1_data(e:Event):Void
	{
		Logging.MLog("on_idx1_data");
		save_idx_chunk();
		if (parse_idx1()) {
			Logging.MLog("parse_idx1 ok");
			idx_stream.addEventListener(ProgressEvent.PROGRESS, function(e:Event):Void { } );
			if (idx_stream.connected)
				idx_stream.close();
			idx_buffer.Clear();
		}
	}
	
	function parse_idx1():Bool
	{
		if (idx_buffer.BytesAvailable(pos_in_idx1_buf) >= 8) {
			var ckid = idx_buffer.ReadInt(pos_in_idx1_buf);
			var cksize = (idx_buffer.ReadInt(pos_in_idx1_buf + 4) + 1) & ~1;
			
			//trace("parse_idx1 ckid=" + ckid + " size=" + cksize + " avail=" + idx_buffer.BytesAvailable(pos_in_idx1_buf));
			
			if (cast(idx_buffer.BytesAvailable(pos_in_idx1_buf), UInt) >= cksize + 8) { //chunk loaded
				//trace("chunk loaded");
				if (ckid == avi_parser.Hex("idx1")) {
					//trace("idx1");
					pos_in_idx1_buf += 8;
					var num_recs = cksize >> 4;
					var x = new Index();
					x.first_frame = 0;					
					x.frames = new Array<StdIndexEntry>();
					
					var ax = new Index(); //audio index
					ax.first_frame = 0;
					ax.frames = new Array<StdIndexEntry>();
					
					var first_offset = -1;
					for (i in 0...num_recs) {
						var id = idx_buffer.ReadInt(pos_in_idx1_buf);
						var flags = idx_buffer.ReadInt(pos_in_idx1_buf + 4);
						var chunk_offset = idx_buffer.ReadInt(pos_in_idx1_buf + 8);
						var chunk_length = idx_buffer.ReadInt(pos_in_idx1_buf + 12);
						if (first_offset < 0)
							first_offset = chunk_offset;
						//trace("idx1 entry i=" + i + " id=" + id + " flags=" + flags + " off=" + chunk_offset + " len=" + chunk_length);
						var e = new StdIndexEntry();
						e.off = chunk_offset;
						e.size = chunk_length;
						e.key = (flags & 16) > 0;		
						switch(id & 0xFF0000) {
							case 0x640000: x.frames.push(e);  //video
							case 0x770000: ax.frames.push(e); //audio
						}
						pos_in_idx1_buf += 16;
					}
					
					var base_offset : Int64;
					var mpos = avi_parser.GetVar("movi_size_pos");
					if (first_offset < Std.int(mpos))
						base_offset = new Int64(mpos + 4, 0);
					else
						base_offset = new Int64(0, 0);

					adjust_index_details(x, base_offset);
					adjust_index_details(ax, base_offset);
					indexes = new Array<Index>();
					indexes.push(x);
					if (ax.frames.length > 0) {
						audio_indexes = new Array<Index>();
						audio_indexes.push(ax);
					}
					//trace("idx1 loaded, updating info");
					update_keyframes_info(0);					
					on_index_loaded();
					
					/*if (x.frames.length > 0) { //test
						var p = x.base_offset.add(x.frames[x.frames.length - 1].off);
						//trace("last frame at " + p.toString());
					}*/
					return true;
				} else { //other chunk
					//trace("not idx1");
					pos_in_idx1_buf += cksize + 8;
					parse_idx1();
				}				
			} //if chunk loaded			
		} //if have data		
		return false;
	}
	
	function adjust_index_details(x : Index, base_offset : Int64):Void
	{
		if (x.frames.length > 0) {
			x.last_frame = x.frames.length - 1;
			x.base_offset = base_offset;
		}		
	}
	
	function start_loading_ixs():Void
	{
		//Logging.MLog("start_loading_ixs() len=" + indexes.length);
		for (ix in 0...indexes.length)
			if (indexes[ix] == null || indexes[ix].frames == null) {
				start_loading_ix(ix);
				return;
			}
		//trace("all ixs loaded"); 			
		/*if (indexes.length > 0) { //test
			var x = indexes[indexes.length - 1];
			var p = x.base_offset.add(x.frames[x.frames.length - 1].off);
			//trace("last frame at " + p.toString());
		}*/
	}
	
	function start_loading_ix(n:Int):Void
	{
		var idx_offset_str = indexes[n].idx_offset.toString();
		var endpos_str = indexes[n].idx_offset.Add(indexes[n].size_in_bytes - 1).toString();
		//Logging.MLog("start_loading_ix n=" + n + " off=" + idx_offset_str + " end=" + endpos_str);
		idx_stream = new PostStream();
		idx_stream.addEventListener(ProgressEvent.PROGRESS, on_ix_data);
		idx_stream.addEventListener(Event.COMPLETE, on_ix_data);		
		idx_buffer = new InputBuffer();		
		idx_stream_start_pos = indexes[n].idx_offset;
		idx_stream.LoadPart(req, idx_offset_str, endpos_str);			
	}
	
	function on_ix_data(e:Event):Void //received some data from idx_stream while loading ix
	{
		save_idx_chunk();
		if (parse_ix(idx_buffer, idx_stream_start_pos)) {
			if (idx_stream.connected) idx_stream.close();
			idx_buffer.Clear();
			if (requested_ix_action != null) {
				var f = requested_ix_action;
				requested_ix_action = null;
				f();
			}
			//if (decoder.NeedsIndex())
			start_loading_ixs();
		}
	}	
	
	override private function find_index(ckid:UInt, ix_pos:Int64):Index 
	{
		if (ckid & 0xFF0000 == 0x770000) { //audio ix 
			for (i in 0...indexes.length)
				if (audio_indexes[i].idx_offset.Eq(ix_pos)) {
					return audio_indexes[i];
				}		
		} 
		return super.find_index(ckid, ix_pos);
	}
	
	override public function GetFrame(num : Int, callers:List<String>) : FrameInfo
	{
		if (num >= frames.length) {
			//trace("num >= frames.length, ->frame_notready");
			return frame_notready;	//should never happen really
		}
			
		if (frames[num] == null || frames[num].data == null) {
			var d = num - avi_parsing_pos;
			if (d >= 0 && d < 100 && avi_parser.active) { //this frame will soon be loaded
				//trace("d >= 0 && d < 100 && avi_parser.active, ->frame_loading");
				requested_frame_num = num;
				return frame_loading;
			}
			//need to seek			
			if (stream.connected) stream.close();	
			//trace("GetFrame(" + num + "): initiate_loading");
			#if callstack
			callers.push("GetFrame " + num + " (just closed stream connection)");
			#end
			initiate_loading(num, callers);
			return frame_loading;
		}
		else 
			return frame_ready(frames[num]);
	}	
	
	override public function GetFrameNotLoading(num : UInt) : FrameInfo
	{
		#if callstack
			return super.GetFrame(num, DataLoader.MkList("GetFrameNotLoading " + num));
		#else			
			return super.GetFrame(num, null);
		#end
	}
	
	override public function NotifyPlayerPosition(pos:Int):Void //pos == frame of interest
	{
		foi_copy = pos;
		if (pos == last_loaded_key_frame && avi_parser.active == false) { //time to load next part
			var i = pos;
			var len:Int = frames.length;
			while (i < len && frames[i] != null && frames[i].data != null)
				i++;
			if (i < len) { //found first frame which is not loaded
				last_loaded_key_frame = -1;
				//trace("NotifyPlayerPosition(" + pos + "): initiate_loading " + i);
				#if callstack
				initiate_loading(i, DataLoader.MkList("NotifyPlayerPosition " + pos));
				#else
				initiate_loading(i, null);
				#end
			}
		}
	}
	
	override function on_index_loaded():Void //either idx1 or indx loaded
	{
		is_index_loaded = true;
		if (requested_index_action != null) {
			var f = requested_index_action;
			requested_index_action = null;
			f();			
		}
	}
	
	function initiate_loading(num:Int, callers:List<String>):Void
	{
		//here frames[num] == null || frames[num].data == null
		//trace("initiate_loading num=" + num);
		/*Logging.MLog("initiate_loading " + num);
		if (callers != null)
			Logging.MLog(" callers: <br/>&nbsp;" + callers.join("<br/>&nbsp;"));*/
		var me = this;
		requested_frame_num = num;
		function action(clr:String): Void->Void { 
			return function():Void { 
				//trace("fire action: initiate_loading "+num);
				#if callstack
				callers.push("fire action" + clr + ": initiate_loading " + num);
				#end
				me.initiate_loading(num, callers); 
			}
		}
		//...
		//make sure we have index info for this frame:
		//  if not is_index_loaded wait for it (idx1 or indx shall be loaded)
		if (!is_index_loaded) {			
			requested_index_action = action("requested_index_action");
			Logging.MLog("..!is_index_loaded, returning");
			return;
		}		
		//  then
		//    find ix such that indexes[ix] contains frame #num				
		var ix = -1;
		for (i in 0...indexes.length) {
			var x = indexes[i];
			if (x.first_frame <= num && x.last_frame >= num) {
		//    if not indexes[ix] loaded 
				if (x.frames == null) {
		//      load indexes[ix]
					requested_ix_action = action("requested_ix_action");
					start_loading_ix(i);
					return;
				}
				ix = i;
				break;
			}
		}		
		if (ix < 0) {
			Logging.MLog("frame not found in index");
			return;
		}
		
		//then
		//  find nearest key frame num Nk	
		// here index[ix] is loaded, so frames[num] is not null and has valid key value
		var nk = -1;
		var i = num;
		var kix = ix;		
		while (frames[i] != null && frames[i].ix >= 0 && !frames[i].key && i > 0) {
			kix = frames[i].ix;
			i--;
		}		
		//here we either found key frame or not enough data
		if (frames[i] == null || frames[i].ix < 0) { //not enough data
			if (kix == 0) {
				Logging.MLog("no key frame in first ix!");
				return;
			}	
			//load missing index and try again
			requested_ix_action = action("requested_ix_action2");
			//Logging.MLog("..index part missing, requesting ix " + ((kix - 1)));
			start_loading_ix(kix - 1);			
			return;
		}		
		//here key frame found
		var nk = i;	
		//trace("..found index: " + nk);
		
		if (stream != null && stream.connected) { //already loading
			Logging.MLog("..already loading, returning");
			return;		
		}		
		//  find first unloaded frame Nu between Nk and num		
		while (frames[i] != null && frames[i].data != null && i <= num)
			i++;
		var nu = i;
		
		clear_memory(nk, num);
		first_frame_loaded = nk;
		cur_last_key_frame = nk;
		
		//start loading data		
		var x = indexes[frames[nu].ix];
		var offset = x.base_offset.Add( x.frames[nu - x.first_frame].off );
		
		reader = start_reading_from_middle;
		buffer = new InputBuffer();
		Parser.input = buffer;
		
		//find next key frame after size limit (don't request whole file)
		var nxk = GetNextKeyFrame(num);
		var end_offset : Null<Int64> = null;
		while (nxk < frames.length - 1) {
			if (frames[nxk] == null) break;
			var nkix = frames[nxk].ix;
			if (nkix < 0 || nkix >= Std.int(indexes.length) || indexes[nkix]==null)
				break;
			var x = indexes[nkix];
			var offset1 = x.base_offset.Add( x.frames[nxk - x.first_frame].off );
			if (offset1.Sub(offset) >= storage_limit) {
				end_offset = offset1;
				break;
			}
			nxk = GetNextKeyFrame(nxk + 1);
		}		
		
		//trace("nk = " + nk + " nu = " + nu);
		avi_parsing_pos = nu;
		reading_start_position = offset;
		last_requested_frame = nxk - 1;
		stop_loading = false;
		stream = new PostStream();
		//stream.endian = Endian.LITTLE_ENDIAN; 
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);	
		stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, on_security_error);
		stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error);
		
		//var sb = new StringBuf();
		//sb.add("..initiate_loading(" + num + "): load from " + offset + " callers:<br/>");
		//sb.add(callers.join("<br/>"));		
		//Logging.MLog(sb.toString());
		
		if (end_offset == null) {
			end_offset = offset.Add(storage_limit + 500000);
			//stream.LoadPart(req, offset.toString());	
		} //else 
		var str = "stream.LoadPart " + offset.toString() + " " + end_offset.toString();
		Logging.MLog(str);
		stream.LoadPart(req, offset.toString(), end_offset.toString());	
	}
	
	function start_reading_from_middle():ReadStatus
	{
		reader = keep_reading;
		avi_parser.StartFromMiddle();	
		stop_loading = false;
		return go_on;
	}
	
	override public function LoadedFramesEnd():Int
	{
		return avi_parsing_pos;
	}
	
	override public function LoadedFramesStart():Int
	{
		return first_frame_loaded;
	}

	function dont_load_too_much(force_stop:Bool):Void
	{
		//Logging.MLog("dltm: sum=" + sum_size_loaded + " limit=" + storage_limit /*+ " kfs=" + sum_key_frames_loaded*/);
		if (!force_stop) {
			if (sum_size_loaded < storage_limit) return; //ok
			if (cur_last_key_frame <= foi_copy) return; // we need next key frame loaded before we stop data transfer
		}
		//Logging.MLog(" too much data, closing connection. force_stop=" + force_stop + " cur_last_key_frame=" + cur_last_key_frame
		//				+ " foi=" + foi_copy);
		if (stream != null && stream.connected) 
			stream.close();			
		stop_loading = true;
		mp3_parser.OnDataEnd();		
		//decide when to load next part...
		//find last loaded key frame
		last_loaded_key_frame = GetNearestKeyframe(avi_parsing_pos);		
	}
	
	function clear_memory(nk:Int, num:Int):Void //forget previously loaded parts - clear all frames except [nk...num] 
	{
		//Logging.MLog("DLAI.clear_memory nk=" + nk + " num=" + num);
		for (i in 0...nk)			
			if (frames[i] != null && frames[i].data!=null && frames[i].data.length != 0)			
				frames[i].data = null;
		for (i in num...frames.length)
			if (frames[i] != null && frames[i].data!=null && frames[i].data.length != 0)
				frames[i].data = null;
		
		sum_size_loaded = 0;	
		for (i in nk...num) 
			if (frames[i] != null) { 
				if (frames[i].data != null)	sum_size_loaded += frames[i].data.length;				
			}				
		sound_buffer.Clear();
		audio_track.Clear();
	}

	override public function SetOnLoadOperComplete(handler : Void->Void):Void
	{		
		requested_frame_action = handler;
	}
	
	override public function AudioTimeLoaded(fps:Float):Float 
	{
		if (reading_start_position.Eq(zero64))
			return super.AudioTimeLoaded(fps);
		else
			return frames.length / fps;
	}

}