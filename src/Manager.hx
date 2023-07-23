package ;

import DataLoader;
import IVideoCodec;
import ScreenPressor;
import js.Lib;
import js.lib.Uint32Array;
import js.lib.Uint8Array;
import lime._internal.graphics.ImageCanvasUtil;
import openfl.display.BitmapData;
import openfl.events.TimerEvent;
import openfl.geom.Rectangle;
import openfl.utils.Timer;
#if indexed
import DataLoaderAVIIndexed;
#else
import DataLoaderAVISeq;
#end
#if msvc
import MSVideo1;
#end
import openfl.utils.ByteArray;
import VideoData;
import js.lib.Int32Array;
import EntroCoders;

enum BufferState {
	trash;
	has_frames(first : Int, last : Int);
}

enum FrameResult {
	decompressed(changes : Null<Bool>);
	soon; //downloaded, decompressing
	notsoon; //not downloaded yet
}

class Manager
{
	var loader : DataLoader;
	var decoder : IVideoCodec;
	var num_buffers : Int;
	var bufs : Array<BufferState>;
	var buffer_size : Int;
	var buffers : Array< Int32Array >;
	var frame_of_interest : Int;
	var fps : Float;
	var next_frame_to_decode : Int;
	var rect : Rectangle;
	var delayed_fill : Int -> Float -> Void;
	var on_open_cb : VideoInfo -> Void;
	var nframes : Int;
	var seek_cb : Void -> Void;
	var last_frame_drawn : Int;
	var on_idecoded : Void -> Void;
	var convert_fromRGB15 : Bool;
	public var shown_time : Float; //time of frame last shown
	public var audio_track(get, null) : AudioTrack;
	var loading_pause : Bool;
	var worker_timer : Timer;
	static inline var INSIGNIFICANT_LINES : Int = 36;

	public function new(nbuffers:Int)
	{
		num_buffers = nbuffers;
		#if indexed
		loader = new DataLoaderAVIIndexed();
		#else
		loader = new DataLoaderAVISeq();
		#end
		bufs = new Array<BufferState>();
		for (i in 0...num_buffers)
			bufs.push(trash);
		shown_time = 0;
		fps = 15.0;
		seek_cb = null;
		last_frame_drawn = -1;
		loading_pause = false;
	}

	public function StopAndClean():Void
	{
		worker_timer.stop();
		worker_timer = null;
		loader.StopAndClean();
		loader = null;
		decoder.StopAndClean();
		decoder = null;
		bufs = null;
		for (i in 0... buffers.length) {
			buffers[i] = null;
		}
		buffers = null;
		delayed_fill = null; on_open_cb = null; seek_cb = null; on_idecoded = null;
	}

	public function Open(url : String, on_open:VideoInfo -> Void):Void
	{
		on_open_cb = on_open;
		loader.Open(url, video_info_cb);
	}

	private function video_info_cb(vi : VideoInfo):Void
	{
		switch(vi.codec) {
			case codec_screenpressor: decoder =	new ScreenPressor(vi.X, vi.Y, num_buffers, vi.bpp);
#if msvc
			case codec_msvc16: decoder = new MSVideo1_16bit(vi.X, vi.Y, num_buffers);
			case codec_msvc8: decoder = new MSVideo1_8bit(vi.X, vi.Y, num_buffers, vi.palette);
#end
		}
		rect = new Rectangle(0, 0, vi.X, vi.Y);
		//addr_buffers = decoder.BufferStartAddr();
		buffer_size = vi.X * vi.Y * 4;
		//var buf_for_conversion = convert_fromRGB15 ? 1 : 0; //now always use one for conv
		buffers = new Array<Int32Array>();
		for (i in 0... num_buffers + 1)
			buffers.push(new Int32Array(buffer_size));

		//var m = new ByteArray();
		convert_fromRGB15 = vi.bpp == 16 && vi.codec==codec_screenpressor;

		/*m.length = addr_buffers + buffer_size * (num_buffers + buf_for_conversion);
		m.position = 0;
		m.endian = Endian.LITTLE_ENDIAN;
		Memory.select(m);*/

		decoder.Preinit(INSIGNIFICANT_LINES);

		//trace("buffer_size = " + buffer_size);
		fps = vi.fps;
		nframes = vi.nframes;
		next_frame_to_decode = 0;
		loader.decoder = decoder;
		if (on_open_cb != null)
			on_open_cb(vi);
		//var str = "video_info_cb: decoder is " + (decoder == null? "null": "" + decoder.NeedsIndex());
		//Logging.MLog(str);
		worker_timer = new Timer(1, 0);
		worker_timer.addEventListener(TimerEvent.TIMER, worker);
		worker_timer.start();
	}

	public function TimeToFraction(time:Float):Float // seconds -> [0..1]
	{
		if (nframes <= 0 || fps == 0.0) return 0;
		var total_time = nframes / fps;
		return time / total_time;
	}

	public function FractionToTime(prc : Float):Float // [0..1] -> seconds
	{
		if (nframes <= 0 || fps == 0.0) return 0;
		var total_time = nframes / fps;
		return prc * total_time;
	}

	public function LoadedFractionEnd():Float //[0..1]
	{
		if (nframes <= 0) return 0;
		var n = loader.LoadedFramesEnd();
		return n / nframes;
	}

	public function LoadedFractionStart():Float //[0..1]
	{
		if (nframes <= 0) return 0;
		var n = loader.LoadedFramesStart();
		return n / nframes;
	}

	public function TotalTime():Float
	{
		if (fps == 0) return 0;
		return nframes / fps;
	}

	public function FrameTime(frm:Int):Float
	{
		if (fps == 0) return 0;
		return frm / fps;
	}

	public function NextFrameTime():Float
	{
		if (fps == 0) return 0;
		var frm = last_frame_drawn + 1;
		return frm / fps + 0.001;
	}

	public function PrevFrameTime():Float
	{
		if (fps == 0 || last_frame_drawn <= 0) return 0;
		var frm = last_frame_drawn - 1;
		return frm / fps + 0.001;
	}

	public function PrevKeyTime():Float
	{
		var key_idx = loader.GetNearestKeyframe(last_frame_drawn-1);
		return FrameTime(key_idx)+0.001;
	}

	public function NextKeyTime():Float
	{
		var key_idx = loader.GetNextKeyFrame(last_frame_drawn+1);
		return FrameTime(key_idx)+0.001;
	}

	public function LoadedAudioTime():Float
	{
		if (fps == 0) return 0;
		return loader.AudioTimeLoaded(fps);
	}

	public function GetDecompressedFrame(time : Float, bitmap_data : BitmapData, playing:Bool): FrameResult
	{
		frame_of_interest = Std.int(time * fps);
		//trace("GetFrame: interest=" + frame_of_interest);
		loader.NotifyPlayerPosition(frame_of_interest);

		for (nb in 0...bufs.length)
			switch(bufs[nb]) {
				case has_frames(first, last):
					if (first <= frame_of_interest && frame_of_interest <= last) {
						shown_time = time;
						fill_bitmap_data(nb, bitmap_data);
						delayed_fill = null;
						return decompressed(loader.GetFrameChanges(frame_of_interest));
					}
				case trash:
			}

		var me = this;
		#if callstack
		var f = loader.GetFrame(frame_of_interest, DataLoader.MkList("GetDecompressedFrame " + time));
		#else
		var f = loader.GetFrame(frame_of_interest, null);
		#end
		switch(f) {
			case frame_notready:
				return notsoon;
			case frame_ready(frm):
				var key_idx = loader.GetNearestKeyframe(frame_of_interest);
				if (next_frame_to_decode < key_idx || next_frame_to_decode > frame_of_interest) { //seek
					next_frame_to_decode = key_idx;
					for (i in 0...bufs.length)
						bufs[i] = trash;
				}
				delayed_fill = function(nb:Int, t:Float):Void { me.shown_time = t; me.fill_bitmap_data(nb, bitmap_data);  };
				return soon;
			case frame_loading:
				loading_pause = true;
				//DataLoader.ELog("GetDecompressedFrame: loader.SetOnLoadOperComplete(repeat this)");
				loader.SetOnLoadOperComplete(function():Void { me.GetDecompressedFrame(time, bitmap_data, playing); me.loading_pause = false; } );
				delayed_fill = function(nb:Int, t:Float):Void { me.shown_time = t; me.fill_bitmap_data(nb, bitmap_data);  };
				return playing ? notsoon : soon; //if got here during playing, pause
		}
		return notsoon;
	}

	public function SeekTo(t : Float, seek_done : Void -> Void, bitmap_data : BitmapData):Bool
	{
		#if logging
		var st = loader.LoadedFramesStart();
		var en = loader.LoadedFramesEnd();
		//DataLoader.ELog("SeekTo " + t + " loaded " + st + "..." + en);
		#end
		switch(GetDecompressedFrame(t, bitmap_data, false)) {
			case decompressed(_), notsoon:
				//DataLoader.ELog("SeekTo: decompressed or notsoon, calling seek_done");
				seek_done();
				return false;
			case soon:
				//DataLoader.ELog("SeekTo: soon, setting seek_cb to seek_done");
				seek_cb = seek_done;
				return true;
		}
	}

	public function WorkerPos() : Float // [0..1]
	{
		if (nframes <= 0) return 0;
		return next_frame_to_decode / nframes;
	}

	static inline var THINK_LIMIT:Float = 0.05; //max time in seconds to think in one go

	public function SkipStills(first_call:Bool) : Null<Float> //time if a change found
	{
		if (first_call) frame_of_interest++;
		#if logging
		var t0 = haxe.Timer.stamp(); //DataLoader.ELog("SkipStills enter frame_of_interest=" + frame_of_interest);
		#else
		var t0 = haxe.Timer.stamp();
		#end
		while(true) { // exit if found or time limit exhausted
			switch(loader.FindPossibleChange(frame_of_interest)) {
				case change(pos):
					frame_of_interest = pos;
					//DataLoader.ELog("return known change at foi=" + frame_of_interest, t0);
					return frame_of_interest / fps;
				case unknown(pos):
					frame_of_interest = pos;
					//DataLoader.ELog("unknown at foi=" + frame_of_interest, t0);
					while (next_frame_to_decode <= frame_of_interest) {
						for(n in 0...10)
							worker(null);
						var t1 = haxe.Timer.stamp();
						if (t1 - t0 > THINK_LIMIT) {
							//DataLoader.ELog("think time limit exhausted", t0);
							return null;
						}
					}
			}
		}
	}


	function get_audio_track():AudioTrack
	{
		return loader == null ? null : loader.audio_track;
	}

	function fill_bitmap_data(nbuf : Int, bitmap_data : BitmapData):Void
	{
		if (frame_of_interest == last_frame_drawn) return; //already drawn
		//var pointer = addr_buffers + nbuf * buffer_size;
		var conv_buffer : Int32Array = buffers[buffers.length - 1];
		var src : Int32Array = buffers[nbuf];
		//var srcBytes = new Uint8Array( src.buffer );
		//var dstBytes = new Uint8Array( conv_buffer.buffer );
		var bdata = bitmap_data.image.buffer.data;

		if (bdata == null) {
			if (convert_fromRGB15) {
				for(i in 0 ... buffer_size) {
					/*var j = i * 4;
					dstBytes[j + 1] = srcBytes[j] << 3;
					dstBytes[j + 2] = srcBytes[j + 1] << 3;
					dstBytes[j + 3] = srcBytes[j + 2] << 3;*/
					conv_buffer[i] = src[i] << 11;
				}
			} else {
				//RGB -> ABGR
				for (i in 0 ... buffer_size) {
					/*var j = i * 4;
					dstBytes[j + 1] = srcBytes[j + 2];
					dstBytes[j + 2] = srcBytes[j + 1];
					dstBytes[j + 3] = srcBytes[j];*/
					var c = src[i];
					//conv_buffer[i] = ((c & 255) << 24) | ((c & 0xFF00) << 8) | ((c & 0xFF0000) >> 8);
                    // conv_buffer[i] =  0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
                    conv_buffer[i] = 0xFF000000 | c;
				}
			}
			//js.Lib.debug();
			var byteArr = ByteArray.fromArrayBuffer( conv_buffer.buffer );
			bitmap_data.setPixels( rect , byteArr );
		} else {
			var dst = new Int32Array( bdata.buffer );
			if (convert_fromRGB15) {
				for(i in 0 ... buffer_size) {
					/*var j = i * 4;
					bdata[j + 0] = srcBytes[j] << 3;
					bdata[j + 1] = srcBytes[j + 1] << 3;
					bdata[j + 2] = srcBytes[j + 2] << 3;
					bdata[j + 3] = 255;*/
					dst[i] = 0xFF000000 | (src[i] << 3);
				}
			} else {
				for (i in 0 ... buffer_size) {
					/*var j = i * 4;
					bdata[j + 0] = srcBytes[j + 2];
					bdata[j + 1] = srcBytes[j + 1];
					bdata[j + 2] = srcBytes[j];
					bdata[j + 3] = 255;*/
					var c = src[i];
					dst[i] = 0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF);
				}
			}
			//set image type to DATA so render() sees it and calls putImageData
			ImageCanvasUtil.convertToData(bitmap_data.image);
			bitmap_data.image.dirty = true;
			bitmap_data.image.version++;
			//js.Lib.debug();
		}

		last_frame_drawn = frame_of_interest;
	}

	function frames_differ_significantly(pnt1 : Int32Array, pnt2 : Int32Array, curfrm : CompressedFrame):Bool
	{
		//var t0 = DataLoader.ELog("frames_differ_significantly nf2dec=" + next_frame_to_decode);
		if (next_frame_to_decode > 0) {
			switch(loader.GetFrameNotLoading(next_frame_to_decode-1)) {
				case frame_ready(frm):
					if (frm.key && frm.data != null) {
						if (frm.data.length == curfrm.data.length) {
							for (i in 0...frm.data.length) {
								if (frm.data[i] != curfrm.data[i])
									return true;
							}
							return false; //two frames are exact copies
						}
						return true; //I frames of different lengths - changes
					}
				case frame_loading, frame_notready:
			}
		} else
			return true;
		var X = Std.int(rect.width), Y = Std.int(rect.height);
		for (i in INSIGNIFICANT_LINES * X ... X*Y) {
			if (pnt1[i] != pnt2[i]) {
				//DataLoader.ELog("compared for changes, found some", t0);
				return true;
			}
		}
		//DataLoader.ELog("compared for changes, false", t0);
		return false;
	}

	//called by Worker
	function get_free_buffer(prev_frame_buf_index : Int):Int // returns -1 if no available bufs
	{
		var oldest_index = -1;
		var oldest_frame = 100000000;
		for (i in 0...bufs.length)
			if (i != prev_frame_buf_index)
				switch(bufs[i]) {
					case trash: return i;
					case has_frames(first, last):
						if (last < frame_of_interest && first < oldest_frame) {
							oldest_frame = first;
							oldest_index = i;
						}
				}
		if (oldest_index >= 0) {
			bufs[oldest_index] = trash;
			return oldest_index;
		}
		return -1;
	}

	function handle_decode_status(state:DecoderState):Void
	{
		switch(state) {
			case zero_state:	on_idecoded();
			case error_occured:	trace("problem decoding key frame " + next_frame_to_decode);
			case in_progress:
		}
	}

	function worker(e:TimerEvent):Void
	{
		//var t_entry = DataLoader.ELog("worker enters, nnf2de=" + next_frame_to_decode + " foi=" + frame_of_interest);
		//try {
		if (decoder.State() == in_progress) {
			var state = decoder.ContinueI();
			handle_decode_status(state);
			//DataLoader.ELog("worked on decoding I", t_entry);
			return;
		}

		if (loading_pause) {
			//DataLoader.ELog("loading_pause, returning", t_entry);
			return;
		}

		var prev_frame = decoder.PreviousFrame();
		var prev_frame_buf_idx = -1;// prev_frame_addr > 0 ? Std.int((prev_frame_addr - decoder.BufferStartAddr()) / buffer_size) : -1;
		for (i in 0 ... buffers.length)
			if (prev_frame == buffers[i]) {
				prev_frame_buf_idx = i; break;
			}
		//loader.ShowBufLens();
		var free_buf_idx = get_free_buffer(prev_frame_buf_idx);
		if (free_buf_idx < 0) {
			if (AudioTrack.works) loader.ParseSound();
			//DataLoader.ELog("no free bufs, exit", t_entry);
			return; //no free bufs to decode to
		}

		#if callstack
		var frame_info = loader.GetFrame(next_frame_to_decode, DataLoader.MkList("worker: get next_frame_to_decode " + next_frame_to_decode));
		#else
		var frame_info = loader.GetFrame(next_frame_to_decode, null);
		#end
		//trace("worker: GetFrame(" + next_frame_to_decode + "): " + frm_inf_s(frame_info));
		switch(frame_info) {
			case frame_notready:
				//DataLoader.ELog("worker: frame_notready, ret", t_entry);
				return; //wait for data to arrive
			case frame_ready(frm):
				//trace("loaded frame " + next_frame_to_decode + ", free_buf_idx=" + free_buf_idx);
				//var pointer = addr_buffers + free_buf_idx * buffer_size;
				var new_frame = buffers[free_buf_idx];
				if (frm.key) {
					on_idecoded = function():Void {
						update_bufs(free_buf_idx, next_frame_to_decode, true);
						if (frm.significant_changes==null)
							frm.significant_changes = frames_differ_significantly(new_frame, prev_frame, frm);
						next_frame_to_decode++;
					}
					//decoder.RenewI();
					Logging.MLog("worker: decompressing I frame " + next_frame_to_decode);
					var decoder_state = decoder.DecompressI(frm.data, new_frame);
					handle_decode_status(decoder_state);
				} else {
					Logging.MLog("worker: decompressing P frame " + next_frame_to_decode + " len=" + frm.data.length);
					var res = decoder.DecompressP(frm.data, new_frame);
					new_frame = res.data_pnt;
					frm.significant_changes = res.significant_changes;
					//trace("DecompressP done");
					if (new_frame != null) { // do nothing if no meaningful data decoded
						if (new_frame == prev_frame) { //no changes
							//DataLoader.ELog("worker: pointer == prev_frame_addr) { //no changes");
							update_bufs(prev_frame_buf_idx, next_frame_to_decode, false);
						} else { //some changes
							//DataLoader.ELog("worker: pointer != prev_frame_addr) { //some changes");
							update_bufs(free_buf_idx, next_frame_to_decode, true);
						}
					} //else	DataLoader.ELog("worker: pointer == 0");
					next_frame_to_decode++;
				}
			case frame_loading:
				loading_pause = true;
				var me = this;
				//DataLoader.ELog("worker: loader.SetOnLoadOperComplete(me.loading_pause = false)");
				loader.SetOnLoadOperComplete(function():Void { me.loading_pause = false; } );
				//DataLoader.ELog("worker: frame_loading, ret", t_entry);
				return;
		}//switch
		/*} catch (ex:openfl.errors.Error) { Logging.MLog("internal error " + ex + ";" + ex.getStackTrace()); }
		  catch (ex:Dynamic) { Logging.MLog("internal error2 " + ex); }*/
		//DataLoader.ELog("worker done in ", t_entry);
		if (e != null && seek_cb != null)
			force_work(10);
	}

	function force_work(n : UInt):Void
	{
		while (n > 0 && seek_cb != null) {
			worker(null);
			n--;
		}
	}

	function decoded(idx: Int, frame_num:Int):Void
	{
		if (frame_num == frame_of_interest) {
			if (delayed_fill != null) {
				//var t0 = DataLoader.ELog("decoded: calling delayed fill");
				var time = frame_num / fps;
				delayed_fill(idx, time);
				delayed_fill = null;
				//DataLoader.ELog("decoded: calling delayed fill done", t0);
			}
			if (seek_cb != null) {
				//DataLoader.ELog("decoded: calling seek_cb");
				seek_cb();
				//DataLoader.ELog("decoded: setting seek_cb=null");
				seek_cb = null;
			}
		}
	}

	function update_bufs(idx:Int, frame_num : Int, new_data : Bool):Void
	{
		var new_val = switch(bufs[idx]) {
			case trash: has_frames(frame_num, frame_num);
			case has_frames(first, last):
				if (new_data || last != frame_num - 1) has_frames(frame_num, frame_num);
				else has_frames(first, frame_num);
		}
		bufs[idx] = new_val;
		decoded(idx, frame_num);
	}
}