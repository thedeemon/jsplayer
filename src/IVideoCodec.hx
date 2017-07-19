package ;
import js.html.Int32Array;
import js.html.Uint8Array;

enum DecoderState {
	zero_state;
	in_progress;
	error_occured;
} 

typedef PFrameResult = {
	data_pnt : Int32Array, // decompressed data: buffer or prevFrame	
	significant_changes : Bool
}
 
interface IVideoCodec 
{
	function Preinit(insignificant_lines : Int):Void; //must be called after memory is allocated
	//function BufferStartAddr():Int;
	function PreviousFrame():Int32Array;
	function IsKeyFrame(data : Uint8Array):Bool;
	function State():DecoderState;
	//function RenewI():Void;
	function DecompressI(src:Uint8Array, dst:Int32Array):DecoderState; //zero_state if done 
	function ContinueI():DecoderState;
	function DecompressP(src:Uint8Array, dst:Int32Array):PFrameResult; 
	function NeedsIndex():Bool;
	function StopAndClean():Void;
}