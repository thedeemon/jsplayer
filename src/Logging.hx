package ;
import haxe.Log;

class Logging 
{
	public static var on : Bool = true;
	
	public static inline function MLog(msg:String, ?pos:haxe.PosInfos)
	{
		#if logging
		if (on)
			Log.trace(msg, pos);
		#end
	}	
	
	public static inline function dbg(msg:String, ?pos:haxe.PosInfos)
	{
		#if debugging
		if (on)
			Log.trace(msg, pos);
		#end
	}	
	public static var extra : Bool = true;
	
	static var elog : Array<TimedMsg> = [];
	public static inline function FastLog(message:String, tstart:Null<Float>, tcur:Float):Void
	{
		elog.push(new TimedMsg(message, tstart, tcur));
		if (elog.length > 4000) extra = false;
	}
	
	public static function FlushLog():String
	{
		var sb = new StringBuf();
		for (x in elog)
			x.toBuf(sb);
		elog = [];
		return sb.toString();
	}
}

class TimedMsg 
{
	var msg : String;
	var t1 : Float;
	var t0 : Null<Float>;
	
	public function new(message:String, tstart:Null<Float>, tcur:Float)
	{
		msg = message; t0 = tstart; t1 = tcur;
	}
	
	public function toBuf(sb:StringBuf):Void
	{
		sb.add("t="); sb.add(t1); sb.add(": "); sb.add(msg); 
		if (t0 != null) {
			sb.add(" dt=");
			sb.add(t1 - t0);
		}
		sb.add("<br/>\n");
	}
}