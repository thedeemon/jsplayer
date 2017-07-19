package ;

import openfl.net.URLRequestHeader;
import openfl.net.URLRequestMethod;
import openfl.net.URLStream;
import openfl.net.URLRequest;
import openfl.net.URLVariables;

class PostStream extends URLStream
{
	public function LoadPart(req:URLRequest, ?from:String, ?to:String):Void 
	{
		var hs = new Array<URLRequestHeader>();
		var vs = new URLVariables();
		if (from != null) {
			hs.push(new URLRequestHeader("s", from));
			vs.s = from;
		}
		if (to != null) {
			hs.push(new URLRequestHeader("e", to));			
			vs.e = to;
		}
		if (hs.length > 0) {
			req.requestHeaders = hs;
			req.data = vs;
		}
			
		req.method = URLRequestMethod.POST;		
		load(req);
	}
	
	public function StopAndClean():Void
	{
		//if (connected)
		close();
	}
	
	public override function get_connected ():Bool {
		trace("PostStream.connected: __data ? " + (__data != null));
		return __data != null;
	}
	
	public override function close():Void {
		if (__data == null) return;
		super.close();
		__loader.close();
	}
}