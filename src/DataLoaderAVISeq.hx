package ;
import DataLoader;
import js.Lib;
import js.lib.Uint8Array;
import openfl.utils.ByteArray;
import haxe.Timer;
import AVIParser;
import MP3Parser;
import IVideoCodec;
import VideoData;

class DataLoaderAVISeq extends DataLoader
{
	public function new()
	{
		super();
	}

	override public function Open(url:String, video_info_callback:VideoInfo -> Void):Void
	{
		//trace("opening " + url);
		reader = start_reading;
		reading_start_position = new Int64(0, 0);
		video_info_cb = video_info_callback;
		avi_parser = new AVIParser(add_frame, on_video_info, add_sound_chunk, on_indx_data, on_ix_read);
		Parser.mem = {};
		Parser.input = buffer;
		mp3_parser = new MP3Parser(sound_buffer, audio_track.AddFragment);
		super.Open(url, video_info_callback);
	}

	function add_frame(arr : ByteArray):Void
	{
		if (arr.length != 0) {
			//skip all zero-length frames created when ix was read
			while (frames[avi_parsing_pos] != null && frames[avi_parsing_pos].data != null && frames[avi_parsing_pos].data.length == 0) {
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
		avi_parsing_pos++;
	}

	function add_sound_chunk(chunk : ByteArray):Void
	{
		if (AudioTrack.works)
			sound_buffer.AddChunk(chunk);
	}

	override public function LoadedFramesEnd():Int
	{
		return avi_parsing_pos;
	}

}