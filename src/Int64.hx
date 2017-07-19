package ;
import openfl.utils.ByteArray;

class Int64 
{
	var low : UInt;
	var hi : UInt;
	
	public function new(low_part : UInt, hi_part : UInt) 
	{
			low = low_part; hi = hi_part;
	}
	
	public static function Read(data : ByteArray) : Int64
	{
		var low = data.readUnsignedInt();
		var hi = data.readUnsignedInt();
		return new Int64(low, hi);
	}
	
	public function toString():String
	{
		//return "{I64 hi=" + hi + " lo=" + low + "}";		
		return Std.string(toFloat());
	}
	
	function toFloat():Float
	{
		var f : Float = hi;
		f *= 65536.0;
		f *= 65536.0;
		f += low;
		return f;
	}
	
	public function Add(a : UInt):Int64
	{
		var low1:UInt = (low + a) & 0xFFFFFFFF;
		var hi1:UInt = low1 < low ? hi + 1 : hi;
		return new Int64(low1, hi1);
	}
	
	public function Eq(a : Int64):Bool
	{
		return low == a.low && hi == a.hi;
	}
	
	public function Sub(a : Int64):Float
	{
		return toFloat() - a.toFloat();		
	}
}