package ;
import openfl.events.Event;
import openfl.events.ProgressEvent;
import openfl.net.Socket;
import openfl.errors.IOError;
import openfl.errors.SecurityError;
import openfl.utils.ByteArray;
import openfl.net.URLRequest;
#if https
import com.hurlant.crypto.tls.TLSSocket;
import com.hurlant.crypto.tls.TLSConfig;
#end
enum HTTPClientState { http_state_header; http_state_chunk; http_state_between; }

class HTTPClient 
{
	var socket : Socket;
	var progress_handler : Event -> Void;
	var host : String;
	var path : String;
	var port : Int;
	var state : HTTPClientState;
	var buffer : ByteArray;
	var chunk_length : UInt;
	var out_buffer : ByteArray;
	var range_start : String;
	var range_end : String;
	public static var cookies : String;
	public var connected(is_connected, null):Bool;
	
	public function new() 
	{		
		state = http_state_header;
		buffer = new ByteArray();
		out_buffer = new ByteArray();
	}
	
	public var bytesAvailable(get_bytesAvailable, null) : UInt;
	public var endian : openfl.utils.Endian;
	
	function get_bytesAvailable():UInt
	{
		return out_buffer.length;
	}
	
	public function readBytes(chunk : ByteArray, pos:UInt, n:UInt):Void
	{
		out_buffer.position = 0;
		out_buffer.readBytes(chunk, pos, n);
		if (out_buffer.bytesAvailable > 0) {			
			var bytes = new ByteArray();
			out_buffer.readBytes(bytes);
			out_buffer = bytes;
		} else 
			out_buffer.clear();
	}
	
	public function load(req:URLRequest):Void
	{
		LoadPart(req);
	}
	
	public function LoadPart(req:URLRequest, ?from:String, ?to:String):Void //like "http://localhost:3000/test"
	{
		var url = req.url;
		//trace("load " + url + (from==null ? "" : " from " + from));
		var re = ~/\/\/(.+?)\//;
		if (!re.match(url)) {
			trace("bad URL: " + url);
			return;
		}
		range_start = from; range_end = to;
		host = re.matched(1);
		
		var https = url.substr(0, 5) == "https";
		var last_colon = host.lastIndexOf(":");
		port = https ? 443 : 80;
		if (last_colon > 5) {
			port = Std.parseInt(host.substr(last_colon + 1));
			host = host.substr(0, last_colon);
		}		
		var third_slash = url.indexOf("/", 8);
		path = url.substr(third_slash);
		
		try {
#if https			
			if (https) {
				var tls = new TLSSocket();
				var conf = new TLSConfig(1);
				conf.ignoreCommonNameMismatch = true;
				conf.trustAllCertificates = true;
				conf.promptUserForAcceptCert = false;
				conf.trustSelfSignedCertificates = true;
				tls.setTLSConfig(conf);
				socket = tls;
				//trace("TLS, port=" + port + " host=" + host);
			} else
#end			
				socket = new Socket();
			socket.addEventListener(Event.CONNECT, on_connect);
			socket.addEventListener(openfl.events.IOErrorEvent.IO_ERROR, on_error);
			socket.addEventListener(openfl.events.SecurityErrorEvent.SECURITY_ERROR, on_error);
			socket.addEventListener(ProgressEvent.SOCKET_DATA, on_data);
			socket.addEventListener(Event.CLOSE, on_close);
			//trace("host=" + host + " port=" + port + " path=" + path + " https=" + https);
			socket.connect(host, port);
		} catch (e:IOError) {
			trace(e);
		} catch (e:SecurityError) {
			trace(e);
		}		
	}
	
	public function addEventListener(evt:String, handler:Event->Void):Void
	{
		//trace("add listener: " + evt);
		progress_handler = handler;
	}
	
	function on_connect(e:Event):Void
	{		
		//trace("on_connect");
		var request = "GET " + path + " HTTP/1.1\r\nHost: " + host + ":" + port + "\r\n";
		if (range_start != null) {
			request += "Range: bytes=" + range_start + "-";
			if (range_end != null)  request += range_end;
			request += "\r\n";
		}
		if (cookies != null) {
			request += "Cookie: " + cookies + "\r\n";
		}
		
		request += "\r\n";
		//trace(request);
		socket.writeUTFBytes(request);
		socket.flush();		
	}
	
	function on_error(e:Event):Void
	{
		trace("error: " + e);
	}
	
	function on_data(e:Event):Void
	{
		//trace("on_data: arrived " + socket.bytesAvailable);
		buffer.position = buffer.length;
		socket.readBytes(buffer, buffer.length, socket.bytesAvailable);
		process_data();
	}
	
	function shift_buffer(n : Int):Void
	{
		buffer.position = n;
		var bytes = new ByteArray();
		buffer.readBytes(bytes);
		buffer = bytes;
	}
	
	function process_data():Void
	{
		switch(state) {
			case http_state_header:				
				var str = buffer.toString();
				var i = str.indexOf('\r\n\r\n');//all header is read
				if (i >= 0) {
					if (str.indexOf("Transfer-Encoding: chunked") >= 0) {					
						state = http_state_between;						
					} else { //not chunked
						chunk_length = 1000000000;
						var li = str.indexOf("Content-Length:");
						if (li >= 0) {
							var k1 = str.indexOf(":", li);
							var k2 = str.indexOf("\r\n", li);
							if (k1 >= 0 && k2 >= 0) {
								var length_string = str.substr(k1 + 2, k2 - k1 - 2);
								var len = Std.parseInt(length_string);
								if (len!=null) chunk_length = len;
							}							
						}
						state = http_state_chunk;
					}
					
					shift_buffer(i + 4);
					process_data();
				}
			case http_state_chunk:
				buffer.position = 0;
				if (buffer.bytesAvailable > 0) {	
					if (buffer.bytesAvailable >= chunk_length) {
						buffer.readBytes(out_buffer, out_buffer.length, chunk_length);	
						shift_buffer(chunk_length);
						progress_handler(null);	
						state = http_state_between;
						process_data();
					} else { //part of chunk
						chunk_length -= buffer.bytesAvailable;
						buffer.readBytes(out_buffer, out_buffer.length);
						buffer.clear();
						progress_handler(null);	
					}
				}
			case http_state_between:
				buffer.position = 0;
				var str = buffer.toString().toLowerCase();
				var i = str.indexOf("\r\n");
				var start = 0;
				if (i == 0) {
					start = 2;
					i = str.indexOf("\r\n", 2);
				}
				if (i > 0) {
					var len = 0;
					var j = start;
					while (j < i) { 
						var code = str.charCodeAt(j);
						if (code >= 48 && code < 58) len = len * 16 + code - 48;
						else
						if (code >= 97 && code <= 102) len = len * 16 + code - 87;
						else break;
						j++;
					}
					if (len > 0) {
						chunk_length = len;
						shift_buffer(i + 2);
						state = http_state_chunk;
						process_data();
					} else { //end of data
						if (socket.connected) socket.close(); 
					}
				}
		}
	}
	
	function on_close(e:Event):Void
	{
		progress_handler(null);	
		//trace("on_close " + e);
	}
	
	public function close():Void
	{
		//trace("HTTPClient.close");
		if (socket.connected)
			socket.close();
	}
	
	function is_connected():Bool
	{
		return socket.connected;
	}
}