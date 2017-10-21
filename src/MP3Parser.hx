package ;
import openfl.display.Loader;
import openfl.events.TimerEvent;
import openfl.utils.ByteArray;
import openfl.utils.Timer;
import InputBuffer;
import openfl.media.Sound;
import openfl.display.LoaderInfo;
import openfl.events.Event;
import openfl.utils.Endian;

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
	var section_handler : Float -> Float -> Sound -> Void; //start, duration, sound
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

	public function new(buffer : InputBuffer, sound_handler : Float -> Float -> Sound -> Void) 
	{
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
	}
	
	public function NoMoreSound():Bool
	{
		return no_more_data && (sections_pending == 0);
	}
	
	public function Parse():Void
	{
		if (parsing_complete) return;
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
		var frame_duration = 1152 / sample_rate;
		var start_time = frame_duration * frames_processed;
		//trace("sample_rate=" + sample_rate + " frame_dur=" + frame_duration);
		
		generate_sound(frames, start_time);
		
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
			generate_long_sound();
	}
	
	function generate_long_sound():Void
	{
		var frame_duration = 1152 / sample_rate;
		var start_time = frame_duration * long_frames_processed;
		//trace("gen_long frame_dur=" + frame_duration + " long_frm_proc=" + long_frames_processed + " start=" + start_time);
		generate_sound(long_frames, start_time);
		var num_saved = 4;
		var last_frames = long_frames.slice( -num_saved );		
		long_frames_processed += long_frames.length - num_saved;
		long_frames = last_frames;
	}
	
	private function generate_sound(mp3frames : Array<Range>, start_time : Float):Bool
	{
		if (mp3frames.length < 1) return false;
		var t0 = haxe.Timer.stamp();
		var swfBytes:ByteArray = new ByteArray();
		swfBytes.endian = Endian.LITTLE_ENDIAN;
		for(b in sound_class_swf_bytes1)		
			swfBytes.writeByte(b);
		
		var swfSizePosition = swfBytes.position;
		swfBytes.writeInt(0); //swf size will go here
		for(b in sound_class_swf_bytes2)		
			swfBytes.writeByte(b);
		
		var audioSizePosition = swfBytes.position;
		swfBytes.writeInt(0); //audiodatasize+7 to go here
		swfBytes.writeByte(1);
		swfBytes.writeByte(0);
		var hd = input.ReadIntBigEndian(mp3frames[0].start);
		swfBytes.writeByte(swf_format_byte(hd));		
		
		var sampleSizePosition = swfBytes.position;
		swfBytes.writeInt(0); //number of samples goes here
		
		swfBytes.writeByte(0); //seeksamples
		swfBytes.writeByte(0);
					
		var frameCount = 0;		
		var byteCount = 0; //this includes the seeksamples written earlier
		var frm_data = new ByteArray();		
					
		var t2 = haxe.Timer.stamp();
		swfBytes.length = swfBytes.length + mp3frames.length * mp3frames[0].length + 2048;
		
		for (rng in mp3frames) 
		{				
			if (frm_data.length < rng.length)
				frm_data.length = rng.length; 
			input.ReadBytes(rng.start, frm_data, 0, rng.length);
			swfBytes.writeBytes(frm_data, 0, rng.length);			
			byteCount += rng.length;
			frameCount++;
		}
		var t3 = haxe.Timer.stamp();
		
		if(byteCount==0)		
			return false;
		
		byteCount+=2;
		var currentPos = swfBytes.position;
		swfBytes.position = audioSizePosition;
		swfBytes.writeInt(byteCount+7);
		swfBytes.position = sampleSizePosition;
		swfBytes.writeInt(frameCount*1152);
		swfBytes.position = currentPos;
		for(b in sound_class_swf_bytes3)
			swfBytes.writeByte(b);
		swfBytes.position = swfSizePosition;
		swfBytes.writeInt(swfBytes.length);
		swfBytes.position=0;
		var swfBytesLoader:Loader = new Loader();
		var me = this;
		sections_pending++;
		var swfCreated = function(ev:Event):Void
			{
				//var t2 = Timer.stamp();				
				var loaderInfo:LoaderInfo = cast(ev.currentTarget , LoaderInfo);
				var soundClass:Class<Dynamic> = cast(loaderInfo.applicationDomain.getDefinition("SoundClass"), Class<Dynamic>);
				var sound:Sound = Type.createInstance(soundClass, []); //new soundClass();				
				//trace("sound created start=" + start_time + " length=" + sound.length/1000 + " dt2=" + (t2 - t0));
				me.sections_pending--;
				me.section_handler(start_time, sound.length / 1000, sound);
			};
		swfBytesLoader.contentLoaderInfo.addEventListener(Event.COMPLETE, swfCreated);
		var t4 = haxe.Timer.stamp();
		swfBytesLoader.loadBytes(swfBytes);
		var t1 = haxe.Timer.stamp();
		/*if (frameCount > FRAMES_IN_SECTION)
			//trace("gensound start=" + start_time + " frames=" + frameCount + " dt=" + (t1 - t0) +
			 " for=" + (t3-t2) + " load=" + (t1-t4));*/
		return true;
	}
	
	private static var sound_class_swf_bytes1:Array<Int> =	[ 0x46 , 0x57 , 0x53 , 0x09 ];
	private static var sound_class_swf_bytes2:Array<Int> =
		[	
			0x78 , 0x00 , 0x05 , 0x5F , 0x00 , 0x00 , 0x0F , 0xA0 , 
			0x00 , 0x00 , 0x0C , 0x01 , 0x00 , 0x44 , 0x11 , 0x08 , 
			0x00 , 0x00 , 0x00 , 0x43 , 0x02 , 0xFF , 0xFF , 0xFF , 
			0xBF , 0x15 , 0x0B , 0x00 , 0x00 , 0x00 , 0x01 , 0x00 , 
			0x53 , 0x63 , 0x65 , 0x6E , 0x65 , 0x20 , 0x31 , 0x00 , 
			0x00 , 0xBF , 0x14 , 0xC8 , 0x00 , 0x00 , 0x00 , 0x00 , 
			0x00 , 0x00 , 0x00 , 0x00 , 0x10 , 0x00 , 0x2E , 0x00 , 
			0x00 , 0x00 , 0x00 , 0x08 , 0x0A , 0x53 , 0x6F , 0x75 , 
			0x6E , 0x64 , 0x43 , 0x6C , 0x61 , 0x73 , 0x73 , 0x00 , 
			0x0B , 0x66 , 0x6C , 0x61 , 0x73 , 0x68 , 0x2E , 0x6D , 
			0x65 , 0x64 , 0x69 , 0x61 , 0x05 , 0x53 , 0x6F , 0x75 , 
			0x6E , 0x64 , 0x06 , 0x4F , 0x62 , 0x6A , 0x65 , 0x63 , 
			0x74 , 0x0F , 0x45 , 0x76 , 0x65 , 0x6E , 0x74 , 0x44 , 
			0x69 , 0x73 , 0x70 , 0x61 , 0x74 , 0x63 , 0x68 , 0x65 , 
			0x72 , 0x0C , 0x66 , 0x6C , 0x61 , 0x73 , 0x68 , 0x2E , 
			0x65 , 0x76 , 0x65 , 0x6E , 0x74 , 0x73 , 0x06 , 0x05 , 
			0x01 , 0x16 , 0x02 , 0x16 , 0x03 , 0x18 , 0x01 , 0x16 , 
			0x07 , 0x00 , 0x05 , 0x07 , 0x02 , 0x01 , 0x07 , 0x03 , 
			0x04 , 0x07 , 0x02 , 0x05 , 0x07 , 0x05 , 0x06 , 0x03 , 
			0x00 , 0x00 , 0x02 , 0x00 , 0x00 , 0x00 , 0x02 , 0x00 , 
			0x00 , 0x00 , 0x02 , 0x00 , 0x00 , 0x01 , 0x01 , 0x02 , 
			0x08 , 0x04 , 0x00 , 0x01 , 0x00 , 0x00 , 0x00 , 0x01 , 
			0x02 , 0x01 , 0x01 , 0x04 , 0x01 , 0x00 , 0x03 , 0x00 , 
			0x01 , 0x01 , 0x05 , 0x06 , 0x03 , 0xD0 , 0x30 , 0x47 , 
			0x00 , 0x00 , 0x01 , 0x01 , 0x01 , 0x06 , 0x07 , 0x06 , 
			0xD0 , 0x30 , 0xD0 , 0x49 , 0x00 , 0x47 , 0x00 , 0x00 , 
			0x02 , 0x02 , 0x01 , 0x01 , 0x05 , 0x1F , 0xD0 , 0x30 , 
			0x65 , 0x00 , 0x5D , 0x03 , 0x66 , 0x03 , 0x30 , 0x5D , 
			0x04 , 0x66 , 0x04 , 0x30 , 0x5D , 0x02 , 0x66 , 0x02 , 
			0x30 , 0x5D , 0x02 , 0x66 , 0x02 , 0x58 , 0x00 , 0x1D , 
			0x1D , 0x1D , 0x68 , 0x01 , 0x47 , 0x00 , 0x00 , 0xBF , 
			0x03 
	];
	private static var sound_class_swf_bytes3:Array<Int> =
	[ 
		0x3F , 0x13 , 0x0F , 0x00 , 0x00 , 0x00 , 0x01 , 0x00 , 
		0x01 , 0x00 , 0x53 , 0x6F , 0x75 , 0x6E , 0x64 , 0x43 , 
		0x6C , 0x61 , 0x73 , 0x73 , 0x00 , 0x44 , 0x0B , 0x0F , 
		0x00 , 0x00 , 0x00 , 0x40 , 0x00 , 0x00 , 0x00 
	];
	
}