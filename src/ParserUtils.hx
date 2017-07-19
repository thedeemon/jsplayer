package ;
import Parser;
class ParserUtils 
{

	public function new() 
	{		
	}
	
	public static function minus(varname : String, ?x : Int, ?expr : Void -> Int) : Void -> Int
	{
		if (x != null)
			return function():Int { return Std.int(/*Reflect.field(Parser.mem, varname)*/Parser.GetVar(varname) - x); };
		if (expr != null)
			return function():Int { return Std.int(/*Reflect.field(Parser.mem, varname)*/Parser.GetVar(varname) - expr()); };
		return function():Int { trace("bad minus result"); return 0; };
	}
	
	public static function plus(varname : String, x : Int) : Void -> Int
	{
		return function():Int { return /*Reflect.field(Parser.mem, varname)*/Parser.GetVar(varname) + x; }
	}
	
	public static function pad(varname : String) : Void -> Int 
	{
		return function():Int { return (/*Reflect.field(Parser.mem, varname)*/Parser.GetVar(varname) + 1) & (~1); };
	}
	
	public static function or(p1 : Parser, p2 : Parser):OrParser
	{
		return new OrParser(p1.clone(), p2.clone());
	}
	
	public static function until(p : Parser, size : Void->Int):LimitedSequenceParser
	{
		return new LimitedSequenceParser(size, p.clone()); 
	}
	
}