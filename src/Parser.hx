package ;
import openfl.utils.ByteArray;
import InputBuffer;
import DataLoader;
import openfl.utils.Endian;

class Parser 
{
	static public var input : InputBuffer;
	static public var current : Void -> Void;
	static public var mem : Dynamic<UInt>; //storage for named parsed int values
	static public var chill : Bool = false;
	
	public var success : UInt -> Void;
	public var fail : Void -> Void;	
	
	public function new() 
	{		
		success = base_success;
		fail = base_fail;
	}
	
	public static function StopAndClean():Void
	{
		input = null;
		current = null;
		ClearMem();
		chill = false;		
	}
	
	
	function base_success(pos:UInt):Void
	{
		trace("Parser.success called");
	}
	
	function base_fail():Void
	{
		trace("Parser.fail called");
	}
	
	public function parse(pos : UInt):Void
	{		
		trace("Parser.parse called");
	}
	
	public function clone():Parser
	{
		trace("Parser.clone called");
		return new Parser();
	}
	
	function wait(pos : UInt):Void
	{
		var me = this;
		current = function():Void { me.parse(pos); }
	}	
	
	function on_success(pos : UInt):Void
	{
		success(pos);
	}
	
	function on_fail():Void
	{
		fail();
	}
	
	public static inline function SetVar(name : String, val : UInt)
	{
		Reflect.setField(mem, name, val);
	}
	
	public static inline function GetVar(name : String):UInt
	{
		return Reflect.field(mem, name);
	}
	
	public static function ClearMem():Void
	{
		mem = {};
	}
}

class IntValParser extends Parser
{
	var const : UInt;
	
	public function new(val : UInt)
	{
		super();
		const = val;
	}
	
	override public function parse(pos : UInt):Void
	{		
		if (Parser.input.BytesAvailable(pos) >= 4) {
			var x = Parser.input.ReadInt(pos);
			if (x == const) success(pos + 4); else fail();
		} else 
			wait(pos);
	}
	
	override public function clone():Parser 
	{
		return new IntValParser(const);
	}
}

class IntVarParser extends Parser
{
	var name: String;
	
	public function new(varname : String)
	{
		super();
		name = varname;
	}
	
	override public function parse(pos : UInt):Void
	{		
		if (Parser.input.BytesAvailable(pos) >= 4) {
			var x = Parser.input.ReadInt(pos);
			Parser.SetVar(name, x);
			//trace("int var set " + name + " = " + x + " at pos=" + pos);
			success(pos + 4);
		} else 
			wait(pos);
	}
	
	override public function clone():Parser 
	{
		return new IntVarParser(name);
	}
}

class IntVarPosParser extends IntVarParser
{
	override public function parse(pos:UInt):Void 
	{
		if (Parser.input.BytesAvailable(pos) >= 4) {
			var x = Parser.input.ReadInt(pos);			
			Parser.SetVar(name, x);
			Parser.SetVar(name+"_pos", pos);
			success(pos + 4);
		} else 
			wait(pos);
	}
	
	override public function clone():Parser 
	{
		return new IntVarPosParser(name);
	}
}

class BlobParser extends Parser
{
	var data_size_thunk : Void -> Int;
	var handler : ByteArray -> Void;
	
	public function new(size_thunk : Void->Int, data_handler  : ByteArray -> Void)
	{
		super();
		data_size_thunk = size_thunk;
		handler = data_handler;
	}
	
	override public function parse(pos : UInt):Void
	{		
		var size = data_size_thunk();
		if (Parser.input.BytesAvailable(pos) >= size) {
			var bytes = new ByteArray();
			bytes.length = size; bytes.position = 0; bytes.endian = Endian.LITTLE_ENDIAN;
			if (size > 0)
				Parser.input.ReadBytes(pos, bytes, 0, size);
			if (handler != null)
				handler(bytes);
			success(pos + size);
		} else 
			wait(pos);
	}
	
	override public function clone():Parser 
	{
		return new BlobParser(data_size_thunk, handler);
	}
}

class JunkBlobParser extends Parser
{
	var data_size_thunk : Void -> Int;
	
	public function new(size_thunk : Void->Int)
	{
		super();
		data_size_thunk = size_thunk;
	}
	
	override public function parse(pos : UInt):Void
	{		
		var size = data_size_thunk();
		if (Parser.input.BytesAvailable(pos) >= size) {
			success(pos + size);
		} else 
			wait(pos);
	}
	
	override public function clone():Parser 
	{
		return new JunkBlobParser(data_size_thunk);
	}
}


class AndParser extends Parser
{
	var parsers : Array<Parser>;
	
	public function new(parsers_array : Array<Parser>)
	{
		super();
		parsers = parsers_array;
		for (p in parsers)
			p.fail = on_fail;
		for (i in 0...parsers.length - 1)
			parsers[i].success = parsers[i + 1].parse;
		parsers[parsers.length - 1].success = on_success;
	}	
	
	override public function parse(pos : UInt):Void
	{
		parsers[0].parse(pos);
	}
	
	override public function clone():Parser 
	{
		var a = new Array<Parser>();
		for (p in parsers)
			a.push(p.clone());
		return new AndParser(a);
	}
}

class OrParser extends Parser
{
	var p1 : Parser;
	var p2 : Parser;
	var my_pos : Int;
	
	public function new(prs1 : Parser, prs2: Parser)
	{
		super();
		p1 = prs1; p2 = prs2;
		p1.success = on_success;
		var me = this;
		p1.fail = function():Void { me.p2.parse(me.my_pos); };
		
		p2.success = on_success;
		p2.fail = on_fail;
	}
	
	override public function parse(pos:UInt):Void
	{
		my_pos = pos;
		p1.parse(pos);
	}
	
	override public function clone():Parser 
	{
		return new OrParser(p1.clone(), p2.clone());
	}
}

class LimitedSequenceParser extends Parser
{
	var data_size_thunk : Void->UInt;
	var p : Parser;
	var start_pos : UInt;
	var size : UInt;
	static var repetitions : Int = 0;
	
	public function new(size_thunk : Void->UInt, parser : Parser)
	{
		super();
		data_size_thunk = size_thunk;
		p = parser;
		p.fail = on_fail;
		p.success = on_return;
	}
	
	function on_return(pos : UInt):Void
	{
		if (pos < start_pos + size) {
			repetitions++;
			if (repetitions > 50) {
				repetitions = 0;
				var prs = p;
				Parser.current = function():Void { prs.parse(pos); }
				Parser.chill = true;
			} else 
				p.parse(pos);
		}
		else {
			on_success(pos);
		}
	}
	
	override public function parse(pos:UInt):Void
	{		
		start_pos = pos;
		size = data_size_thunk();
		p.parse(pos);
	}
	
	override public function clone():Parser 
	{
		return new LimitedSequenceParser(data_size_thunk, p.clone());
	}
}

class OnceParser extends Parser
{
	var p : Parser;
	var start_pos : UInt;
	
	public function new(prs : Parser)
	{
		super();
		p = prs;
		p.fail = on_fail;
		p.success = on_success;
	}
	
	override public function parse(pos:UInt):Void 
	{
		start_pos = pos;
		p.parse(pos);
	}
	
	override private function on_success(pos:UInt):Void 
	{
		Parser.input.DontNeedUpTo(start_pos);
		super.on_success(pos);
	}
	
	override public function clone():Parser 
	{
		return new OnceParser(p.clone());
	}	
}

class ParserUser  //some helper methods
{
	public function new()
	{		
		SomeInt = new IntVarParser("someint");
	}
	
	function Const(?x : UInt, ?s : String):IntValParser
	{
		if (s != null) x = Hex(s); 		
		return new IntValParser(x);		
	}
	
	public function Hex(s : String):UInt
	{
		return (s.charCodeAt(3) << 24) + (s.charCodeAt(2) << 16) + (s.charCodeAt(1) << 8) + s.charCodeAt(0);
	}
	
	function Var(name : String):IntVarParser
	{
		return new IntVarParser(name);
	}

	function VarP(name : String):IntVarPosParser
	{
		return new IntVarPosParser(name);
	}
	
	function seq(a : Array<Dynamic>):AndParser
	{		
		var arr : Array<Parser> = new Array<Parser>();
		for (p in a)
			arr.push(p);
		return new AndParser(arr);
	}	
	
	function Blob(?size_thunk : Void->Int, ?data_handler : ByteArray -> Void, ?const_size : Int):Parser
	{
		if (size_thunk == null) size_thunk = function():Int { return const_size; };
		if (data_handler == null) return new JunkBlobParser(size_thunk);
		return new BlobParser(size_thunk, data_handler);
	}	
	
	public inline function GetVar(name:String):UInt
	{
		return Parser.GetVar(name);
	}
	
	function once(p : Parser):Parser
	{
		return new OnceParser(p);
	}	
	
	var SomeInt : IntVarParser;	
}
