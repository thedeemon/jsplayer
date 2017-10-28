package ;

import js.Browser;
import js.html.XMLHttpRequest;
import openfl.events.TimerEvent;
import openfl.net.URLRequestHeader;
import openfl.net.URLRequestMethod;
//import openfl.net.URLStream;
import openfl.net.URLRequest;
import openfl.net.URLVariables;
import openfl.utils.Endian;
import openfl.utils.ByteArray;
import openfl.events.Event;
import openfl.events.ProgressEvent;
import openfl.events.IOErrorEvent;
import openfl.utils.Timer;

class PostStream 
{	
	public var connected(get, never):Bool;
	public var endian : Endian;
	public var bytesAvailable(get, never):UInt;
	
	var xr : XMLHttpRequest;
	var curState : Int;
	var readPos : Int;
	var stateChanging : Bool;
	var stateChanged : Bool;
	var loadTimer : Timer;	
	//event listeners
	var onProgress : Dynamic -> Void;
	var onComplete : Dynamic -> Void;
	var onError    : Dynamic -> Void;
	
	public function new() {
		xr = new XMLHttpRequest();
		xr.overrideMimeType("text/plain; charset=x-user-defined");
		curState = 0; readPos = 0;
		stateChanging = false;
	}
		
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
	
	public function load(request:URLRequest):Void {
		xr.open("POST", request.url);
		xr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
		xr.onreadystatechange = onStateChange;
		xr.onerror = function() {
			if (onError != null) {
				var e = new Event(IOErrorEvent.IO_ERROR);
				onError(e);
			}
		};
		
		var s = request.requestHeaders.map(function(h) { return h.name + "=" + h.value; }).join("&");
		Logging.MLog("PostStream sending request to " + request.url + " with " + s);
		xr.send(s);
	}
		
	function progressTimer(te:TimerEvent):Void {
		if (!stateChanged) return;
		stateChanged = false;
		
		curState = xr.readyState;
		//Logging.MLog("PostStream.onStateChange state="+ curState);
		if (stateChanging) return;
		stateChanging = true;
		if (onProgress != null && (curState == 3 || curState == 4)) {
			//var dt = Browser.window.performance.now() - time0;
			//Logging.MLog(" onStateChange dt=" + dt);
			
			var e = new ProgressEvent(ProgressEvent.PROGRESS, false, false, xr.responseText.length, 0);
			onProgress(e);
		}
		if (onComplete != null && curState == 4) {
			var e = new Event(Event.COMPLETE);
			onComplete(e);
		}
		stateChanging = false;		
	}
	
	function onStateChange() {
		stateChanged = true;
		if (loadTimer == null) {
			loadTimer = new Timer(250, 0);
			loadTimer.addEventListener(TimerEvent.TIMER, progressTimer);
			loadTimer.start();
			progressTimer(null);
		}		
	}
	
	public function StopAndClean():Void
	{
		if (connected) 
			close();
		xr = null;
		onError = null; onProgress = null; onComplete = null;
		if (loadTimer != null) {
			loadTimer.stop();
			loadTimer = null;
		}
	}
	
	public function get_connected ():Bool {
		var isit = curState == 2 || curState == 3;
		//Logging.MLog("PostStream.connected: " + isit);
		return isit;
	}
	
	public function close():Void {
		if (xr != null) xr.abort();
	}
	
	public function get_bytesAvailable() {
		if (xr==null || xr.responseText==null) return 0;
		return xr.responseText.length - readPos;
	}

	public function readBytes (bytes: ByteArray, offset:UInt = 0, length:UInt = 0):Void {
		var txt = xr.responseText;
		bytes[offset + length - 1] = 0;
		for (i in 0...length)
			bytes[offset + i] = txt.charCodeAt(readPos + i) & 255;
		readPos += length;
	}
	
	/*	 calls:	
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);		
		idx_stream.addEventListener(ProgressEvent.PROGRESS, on_idx1_data);
		idx_stream.addEventListener(Event.COMPLETE, on_idx1_data);		
		idx_stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error_idx);
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);	
		stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error);
		stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, on_security_error);
		idx_stream.addEventListener(ProgressEvent.PROGRESS, on_ix_data);
		idx_stream.addEventListener(Event.COMPLETE, on_ix_data);		
		idx_stream.addEventListener(ProgressEvent.PROGRESS, function(e:Event):Void { } );
		stream.addEventListener(ProgressEvent.PROGRESS, on_progress);
		stream.addEventListener(Event.COMPLETE, on_complete);	
		stream.addEventListener(SecurityErrorEvent.SECURITY_ERROR, on_security_error);
		stream.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error);

		function on_progress(e:ProgressEvent):Void
		function on_complete(e:Event):Void
		function on_security_error(event : SecurityErrorEvent):Void {
		function on_error(e:Event):Void
		function on_error_idx(e:Event):Void
	 * 
	 * */
		
	 
	public function addEventListener (type:String, listener:Dynamic -> Void):Void {
		//trace("PostStream.addEventListener type=" + type);
		if (type == ProgressEvent.PROGRESS)	onProgress = listener; 
		if (type == Event.COMPLETE) onComplete = listener;
		if (type == openfl.events.IOErrorEvent.IO_ERROR) onError = listener;
	}
}

class GetStream extends PostStream {
	public function new() { super(); }
	
	override public function load(request:URLRequest):Void 
	{
		xr.open("GET", request.url);
		xr.setRequestHeader("Content-type", "application/x-www-form-urlencoded");
		xr.onreadystatechange = onStateChange;
		xr.onerror = function() {
			if (onError != null) {
				var e = new Event(IOErrorEvent.IO_ERROR);
				onError(e);
			}
		};
		
		//var s = request.requestHeaders.map(function(h) { return h.name + "=" + h.value; }).join("&");
		Logging.MLog("GetStream sending request to " + request.url);
		xr.send(null);
	}
}