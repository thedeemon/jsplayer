package ;
import js.Lib;
import js.lib.Uint8Array;
import openfl.display.Loader;
import openfl.events.TimerEvent;
import openfl.utils.ByteArray;
import openfl.utils.Timer;
import InputBuffer;
import openfl.display.LoaderInfo;
import openfl.events.Event;
import openfl.utils.Endian;
import WASound;

typedef Range = {
	var start : UInt;
	var length : UInt;
}

class MP3Parser
{
	var input : InputBuffer;
	var position : UInt;
	var frames : Array<Range>;
	var sample_rate : Int;
	var frames_processed : Int;
	var section_handler : Float -> Uint8Array -> Bool -> Void; //(start, sound data, last?)
	var long_frames : Array<Range>;
	var long_frames_processed : Int;
	var no_more_data : Bool;
	var parsing_complete : Bool;
	var sections_pending : Int;
	public var started(default, null) : Bool;

	private static var versions : Array<String> = ["2.5", "err", "2", "1"];
	private static var sampling_rates : Array<Int> = [44100, 48000, 32000];
	private static var bitrates : Array<Int> = [ -1, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320,
		-1, -1, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, -1];
	private static inline var FRAMES_IN_SECTION : Int = 200; //~5 sec
	private static inline var FRAMES_IN_LONG_SECTION : Int = 2300; //~1 min

	public function new(buffer : InputBuffer, sound_handler : Float -> Uint8Array -> Bool -> Void)
	{
		Logging.MLog("new MP3Parser");
		input = buffer;
		section_handler = sound_handler;
		position = 0;
		frames = new Array<Range>();
		frames_processed = 0;
		long_frames = new Array<Range>();
		long_frames_processed = 0;
		no_more_data = false;
		parsing_complete = false;
		sections_pending = 0;
		started = false;
		sample_rate = 44100;
	}

	public function NoMoreSound():Bool
	{
		return no_more_data && (sections_pending == 0);
	}

	public function Parse():Void
	{
		if (parsing_complete) return;
		Logging.MLog("MP3 Parse()");
		var t0 = haxe.Timer.stamp();
		var t1 = t0;
		var repeat = false;
		do {
			repeat = do_parse();
			t1 = haxe.Timer.stamp();
			if (!repeat && no_more_data) {
				parsing_complete = true;
				generate_short_sound(true);
			}
			if (t1 - t0 > 0.025) repeat = false;
		} while (repeat);
	}

	public function OnDataEnd():Void
	{
		no_more_data = true;
	}

	function do_parse():Bool //true if keep going
	{
		while (input.BytesAvailable(position) >= 4) {
			var hd = input.ReadIntBigEndian(position);
			if (is_valid_header(hd)) {
				var size = frame_size(hd);
				if (input.BytesAvailable(position) >= size) {
					add_mp3_frame( { start : position, length : size } );
					position += size;
					return true;
				} else
					return false;
			}
			position++;
		}
		return false;
	}

	function add_mp3_frame(rng : Range):Void
	{
		//Logging.MLog("add_mp3_frame rng.start=" + rng.start);
		frames.push( rng );
		if (frames.length >= FRAMES_IN_SECTION)
			generate_short_sound(false);
		started = true;
	}

	private inline function is_valid_header(headerBits:Int):Bool
	{
	    return (((frame_sync(headerBits)      & 2047)==2047) &&
                ((version_index(headerBits)   &    3)!=   1) &&
                ((layer_index(headerBits)     &    3)!=   0) &&
                ((bitrate_index(headerBits)   &   15)!=   0) &&
                ((bitrate_index(headerBits)   &   15)!=  15) &&
                ((frequency_index(headerBits) &    3)!=   3) &&
                ((emphasis_index(headerBits)  &    3)!=   2)    );
	}

	private function frame_size(header_bytes:Int):Int
	{
		var version = version_index(header_bytes);
		var bitRate = bitrate_index(header_bytes);
		var samplingRate = frequency_index(header_bytes);
		var padding = padding_bit(header_bytes);
		var channelMode = mode_index(header_bytes);
		var actualVersion = versions[version];
		sample_rate = sampling_rates[samplingRate];
		switch(actualVersion)
		{
			case "2":	sample_rate >>= 1;
			case "2.5": sample_rate >>= 2;
		}
		var bitRatesYIndex=(((actualVersion=="1")?0:1)*bitrates.length) >> 1;
		var actualBitRate=bitrates[bitRatesYIndex+bitRate]*1000;
		var frameLength=(((actualVersion=="1"?144:72)*actualBitRate)/sample_rate)+padding;
		return Std.int(frameLength);
	}

	private inline function frame_sync(header_bits:Int):Int
	{
	    return (header_bits>>21) & 2047;
	}

	private inline  function version_index(header_bits:Int):Int
    {
        return (header_bits>>19) & 3;
    }

    private inline function layer_index(header_bits:Int):Int
    {
        return (header_bits>>17) & 3;
    }

    private inline function bitrate_index(header_bits:Int):Int
    {
        return (header_bits>>12) & 15;
    }

    private inline function frequency_index(header_bits:Int):Int
    {
        return (header_bits>>10) & 3;
    }

    private inline function padding_bit(header_bits:Int):Int
    {
        return (header_bits>>9) & 1;
    }

    private inline function mode_index(header_bits:Int):Int
    {
        return (header_bits>>6) & 3;
    }

    private inline function emphasis_index(header_bits:Int):Int
    {
        return header_bits & 3;
    }

	private inline function swf_format_byte(header_bytes:Int):Int
	{
		var channel_mode = mode_index(header_bytes);
		var channels = (channel_mode > 2)?1:2;
		var version = version_index(header_bytes);
		var actual_version = versions[version];
		var sampling_rate = frequency_index(header_bytes);
		sample_rate = sampling_rates[sampling_rate];
		switch(actual_version)
		{
			case "2":	sample_rate >>= 1;
			case "2.5": sample_rate >>= 2;
		}

		var sample_rateIndex = 4 - Std.int(44100 / sample_rate);
		//trace("swf_format_byte sample_rate=" + sample_rate + " index=" + sample_rateIndex + " chan=" + channels);
		return (2 << 4) + (sample_rateIndex << 2) + (1 << 1) + (channels - 1);
	}

	function generate_short_sound(last_portion : Bool):Void
	{
		Logging.MLog("generate_short_sound last=" + last_portion);
		var frame_duration = 1152 / sample_rate;
		var start_time = frame_duration * frames_processed;
		//trace("sample_rate=" + sample_rate + " frame_dur=" + frame_duration);
		//js.Lib.debug();
		if (!last_portion)
			generate_sound(frames, start_time, false);

		var to_long = last_portion ? frames : frames.slice(0, -4);
		for (f in to_long)
			long_frames.push(f);

		if (last_portion) {
			frames_processed += frames.length;
			frames = [];// .length = 0;
		} else {
			var num_saved = 4;
			var last_frames = frames.slice( -num_saved );
			frames_processed += frames.length - num_saved;
			frames = last_frames;
		}

		if (long_frames.length >= FRAMES_IN_LONG_SECTION || last_portion)
			generate_long_sound(last_portion);
	}

	function generate_long_sound(last : Bool):Void
	{
		var frame_duration = 1152 / sample_rate;
		var start_time = frame_duration * long_frames_processed;
		generate_sound(long_frames, start_time, last);
		var num_saved = 4;
		var last_frames = long_frames.slice( -num_saved );
		long_frames_processed += long_frames.length - num_saved;
		long_frames = last_frames;
	}

	private function generate_sound(mp3frames : Array<Range>, start_time : Float, last : Bool):Void
	{
		if (mp3frames.length < 1) return;

		var sumLength : UInt = 0;
		for (f in mp3frames) sumLength += f.length;
		var data = new Uint8Array(sumLength);
		var off = 0;
		for (f in mp3frames) {
			input.ReadToArray(f.start, data, off, f.length);
			off += f.length;
		}
		section_handler(start_time, data, last);
	}

}//MP3Parser