package ;
import js.html.audio.AudioContext;
import js.html.audio.AudioBuffer;
import js.html.audio.AudioBufferSourceNode;
import AudioTrack;

class WASound {
	var abuf : AudioBuffer;
	var node : AudioBufferSourceNode;
	
	public function new(b : AudioBuffer) {
		abuf = b;
	}

	public function play(t:Float) {
		Logging.MLog("node.start(0, " + t + ")");
		node = AudioTrack.makeNode(abuf);
		node.start(0, t); 
	}
	
	public function stop() {
		if (node != null) 
			node.stop();
	}
}