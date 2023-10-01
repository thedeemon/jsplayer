package ;
import js.Lib;
import js.html.audio.AudioBuffer;
import js.html.audio.AudioBufferSourceNode;
import openfl.utils.Timer;
import openfl.events.TimerEvent;
import js.html.audio.AudioContext;
import js.html.Uint8Array;
import WASound;
import Logging;

class Fragment {
    public var start_time(default, null) : Float;
    public var duration(default, null) : Float;
    public var sound(default, null) : WASound;

    public function new(start:Float, dur:Float, snd:WASound)
    {
        start_time = start; duration = dur; sound = snd;
    }

    public inline function end_time():Float
    {
        return start_time + duration;
    }

    public function toString():String
    {
        return "start_time: " + start_time + " duration: " + duration + " end=" + end_time();
    }
}

class AudioTrack
{
    var sections : Array<Fragment>;
    var next_sec_timer : Timer;
    //var sound_channel : SoundChannel;
    var playing_sound : WASound;
    public var time_loaded(default, null) : Float;
    static var ctx : AudioContext;
    public static var works : Bool;

    public function new()
    {
        sections = new Array<Fragment>();
        works = false;
        try {
            ctx = new AudioContext();
            works = true;
        } catch (e:Dynamic) { trace("WebAudio API not accessible"); }
        time_loaded = 0;
    }

    public function AddFragment(start : Float, data : Uint8Array, last : Bool):Void
    {
        Logging.MLog("ATrack.AddFragment start=" + start);
        if (!works) return;
        ctx.decodeAudioData(data.buffer, function(s:AudioBuffer) {
                Logging.MLog("decoded dur=" + s.duration);
                var wasound = new WASound(s);
                addFragmentSound(start, s.duration, wasound, last);
            },
            function() { Logging.MLog("decode failed for fragment at t=" + start); }
        );
    }

    public static function makeNode(b : AudioBuffer) : AudioBufferSourceNode {
        var srcnode = ctx.createBufferSource();
        srcnode.buffer = b;
        srcnode.connect( ctx.destination );
        return srcnode;
    }

    function addFragmentSound(start : Float, dur : Float, snd : WASound, last : Bool):Void //dur in seconds
    {
        Logging.MLog("ATrack.addFragmentSound start="+start + " dur="+dur);
        var frag = new Fragment(start, dur, snd);
        var i:Int = 0;
        var len = sections.length;

        if (len == 0) {
            sections.push(frag);
            if (start < 0.001)
                time_loaded = start + dur;
            return;
        }

        //if (dur > 60)
        //    js.Lib.debug();

        while (i < len && start - sections[i].start_time > 0.001)
            i++;

        var tmplist = sections.slice(0, i);
        tmplist.push(frag);
        if (last) {
            sections = tmplist;
        } else {
            tmplist = tmplist.concat(sections.slice(i)); //tmplist.length == len+1 ,  tmplist.length > 1

            var newlist = new Array<Fragment>();
            var time_covered:Float = 0;
            if (tmplist[1].start_time > tmplist[0].start_time + 0.001 || tmplist[0].end_time() > tmplist[1].end_time() + 0.001) {
                newlist.push(tmplist[0]);
                time_covered = tmplist[0].end_time();
            }
            for (j in 1...len)
                if (tmplist[j + 1].start_time < time_covered + 0.001 &&    //if neighbors touch each other
                    tmplist[j + 1].end_time() > tmplist[j].end_time()) {   //and the second ends later than this
                        //skip
                    } else {
                        newlist.push(tmplist[j]);
                        time_covered = tmplist[j].end_time();
                    }

            if (tmplist[len].end_time() - time_covered > 0.001)
                newlist.push(tmplist[len]);

            sections = newlist;
        }
        time_loaded = 0;
        for (sec in sections)
            if (sec.start_time - time_loaded < 0.001)
                time_loaded = sec.end_time();
    }

    public function Play(time : Float):Bool //false if no sound yet
    {
        if (!works) return false;
        var idx = find_section(time);
        if (idx < 0) {
            //Logging.MLog("Play: section not found for time=" + time);
            return false;
        }
        Logging.MLog("ATrack.Play time=" + time);
        var sec = sections[idx];
        var off = time - sec.start_time;
        if (next_sec_timer != null) {
            next_sec_timer.stop();
            next_sec_timer = null;
        }
        Logging.MLog("sec[" + idx + "]: start=" + sec.start_time + " dur=" + sec.duration);
        sec.sound.play(off);
        if (playing_sound != null)
            playing_sound.stop();
        playing_sound = sec.sound;

        if (idx < sections.length - 1) {
            var next_time = sections[idx + 1].start_time;
            var rest = next_time - time;
            next_sec_timer = new Timer(rest * 1000, 1);
            var me = this;
            next_sec_timer.addEventListener(TimerEvent.TIMER, function(e:TimerEvent):Void { me.Play(next_time); } );
            next_sec_timer.start();
        }
        return true;
    }

    public function Stop():Void
    {
        if (next_sec_timer != null) {
            next_sec_timer.stop();
            next_sec_timer = null;
        }
        if (playing_sound != null) {
            playing_sound.stop();
            playing_sound = null;
        }
    }

    public function Clear():Void
    {
        Stop();
        sections = [];//.length = 0;
        time_loaded = 0;
    }

    public function StopAndClean():Void
    {
        Logging.MLog("ATrack.StopAndClean");
        Stop(); Clear();
    }

    function find_section(time : Float):Int
    {
        var lo:Int = 0;
        var hi = sections.length;
        while (lo < hi) {
            var mid = (lo + hi) >> 1;
            var midsec = sections[mid];
            var next_start = mid < sections.length - 1 ? sections[mid + 1].start_time : midsec.end_time();
            if (time >= midsec.start_time && time < next_start) {
                return mid;
            }
            if (time < sections[mid].start_time)
                hi = mid;
            else
                lo = mid + 1;
        }
        return -1;
    }
}
