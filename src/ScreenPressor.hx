package ;
import openfl.Memory;
import openfl.utils.ByteArray;
import openfl.Vector;
import openfl.utils.Endian;
import IVideoCodec;
import js.html.Int32Array;
import js.html.Uint8Array;
import js.html.Uint32Array;
import js.Lib as JsLib;
import EntroCoders;

typedef DecoderContext = {
	var di : Int;
	var ptype : Int;
	var src : Uint8Array;
	var dst : Int32Array;
	var last_position : Int; // pos in src
}

class ScreenPressor implements IVideoCodec
{
	public static inline var msr_x = 256; //motion search ranges 
	public static inline var msr_y = 256;
	static inline var msrlow_x = 8;
	static inline var msrlow_y = 8; 

	var cx : Int;
	var cx1 : Int;
	var ec : EntroCoderRC;
    var SC_CXSHIFT : Int;
	var X : Int;
	var Y : Int;
	var prevFrame : Int32Array;
	//var prev_frame : Int; //pointer
	var nbx : Int;
	var nby : Int;
	var bts: Vector<Int>;
	var bpp : Int;
	var decoder_state : DecoderState;
	var decoder_context : DecoderContext;
	var insignificant_blocks : Int;
	var insign_lines : Int;
	var decodedI : Bool;
	var last_one_was_flat : Null<Int>;
	
	inline function MAKECX1():Void
	{
		cx1 = (cx << 6) & 0xFC0;
	}
	
		
	static inline var addr_end_tables = 0;// addr_mvtab + (msr_x * 2 + 1  + msr_y * 2 + 1) * 4;
	
	public function new(width:Int, height:Int, num_buffers:Int, bits_per_pixel:Int) //num_frames - number of decompressed frames to store in memory
	{
		//trace("ScreenPressor.new: bpp=" + bits_per_pixel + " w=" + width + " h=" + height);
		X = width; Y = height; bpp = bits_per_pixel;
		decoder_state = zero_state;
		decoder_context = null;
		SC_CXSHIFT = bpp == 16 ? 0 : 2;		
		ec = new EntroCoderRC();
		nbx = Std.int((X + 15) / 16);
		nby = Std.int((Y + 15) / 16);
		bts = new Vector(nbx * nby);		
		decodedI = false;
	}
	
	public function StopAndClean():Void
	{
		bts = null; ec = null; prevFrame = null; //cntab = null;
	}
	
	public function Preinit(insignificant_lines : Int):Void //must be called after memory is allocated
	{
		//trace("SP.Preinit");
		ec.preinit();
		insignificant_blocks = nbx * Std.int((insignificant_lines + 15) / 16);
		insign_lines = insignificant_lines;
	}
		
	public function PreviousFrame():Int32Array
	{
		return prevFrame;
	}
	
	public function IsKeyFrame(data : Uint8Array):Bool
	{
		if (data == null || data.length == 0) return false;
		return (data[0] == 0x12 || data[0] == 0x11);
	}
	
	public function State():DecoderState
	{
		return decoder_state;
	}
	
	public function RenewI():Void
	{
		//trace("SP.RenewI");
		//prev_frame = 0;
		prevFrame = null;
		if (last_one_was_flat != null) return;
		ec.renewI();
	}
	
	public function DecompressI(src:Uint8Array, dst:Int32Array):DecoderState //zero_state if done 
	{
		var di = 0; //start of decompressed data
		var end = X * Y;
		var clr = 0; var lasti = di;
		
		//trace("SP.DecompressI src.size=" + src.length + " bpp="+bpp + " rnd=" + Math.random());
		if (decoder_state == zero_state) {
			//src.position = 0;
		
			var head = src[0];// .readByte();
			if (head == 0x11) { //flat
				var clr = 0;
				if (bpp == 16) {
					var clr16 = src[0] + src[1] * 256;// .readUnsignedShort();
					var b = (clr16 & 0x1F) << 3;
					var g = ((clr16 >> 5) & 0x1F) << 3;
					var r = ((clr16 >> 10) & 0x1F) << 3;
					clr = (r << 16) + (g << 8) + b;
				} else	{
					var b = src[1];// .readUnsignedByte();
					var g = src[2];// .readUnsignedByte();
					var r = src[3];// .readUnsignedByte();
					clr = (r << 16) + (g << 8) + b;
				}
				if (last_one_was_flat != clr) {
					for (di in 0...end)
						dst[di] = clr;
				}
				//prev_frame = buffer_address; //?
				prevFrame = dst;
				last_one_was_flat = clr;
				decodedI = true;
				return zero_state;
			} else
				last_one_was_flat = null;
			if (head != 0x12) {
				trace("unknown version of the codec"); return error_occured;
			}
			//rc.DecodeBegin(src);
			RenewI();
			ec.DecodeBegin(src, 1);

			cx = cx1 = 0;
			var k = 0; 
			
			lasti = di;
			while(k<X+1) {
				//var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				var r = ec.decodeClr(cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = r>>SC_CXSHIFT;
				var g = ec.decodeClr(4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = g>>SC_CXSHIFT;
				var b = ec.decodeClr(2*4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = b>>SC_CXSHIFT;			
			
				var n = ec.decodeN(0); //rc.DecodeVal(ntab[0], 256, SC_NSTEP);
				clr = (b << 16) + (g << 8) + r;
				k += n;

				while(n-->0) {
					dst[di] = clr;
					di++;
				}		
				lasti = di - 1;			
				
			}
		} //if zero_state
		var off = -X  - 1;
		var ptype = 0;	
		var last_pos = 0;
		var dstbytes = new Uint8Array( dst.buffer );

		/*if (decoder_state == in_progress) { //continue
			di = decoder_context.di;
			ptype = decoder_context.ptype;
			last_pos = decoder_context.last_position;
			lasti = di - 1;
		}*/
		var last_di_segment = di & 0xFFFF0000; //?
		
		while(di < end) {
			ptype = ec.decodeP(ptype);//rc.DecodeVal(ptypetab[ptype], 6, SC_UNSTEP);
			if (ptype==0) {
				var r = ec.decodeClr(cx + cx1);//rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = r >> SC_CXSHIFT;
				var g = ec.decodeClr(4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = g >> SC_CXSHIFT;
				var b = ec.decodeClr(2*4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = b >> SC_CXSHIFT;		
				clr = (b << 16) + (g << 8) + r;
			}			
			var n = ec.decodeN(ptype); //rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);

			switch(ptype) {
				case 0:  
					while (n-->0) {
						dst[di++] = clr;  
					}
					lasti = di - 1;
				case 1:
					while (n-->0) {
						dst[di] = dst[lasti]; lasti = di; di++;                  
					}
					clr = dst[lasti];					
				case 2:
					while (n-->0) {
						clr = dst[di + off + 1];
						dst[di] = clr; di++;                  
					}
					lasti = di - 1;
				case 4:
					while (n-->0) {
						var r = dstbytes[lasti*4] + dstbytes[(di + off)*4 + 4] - dstbytes[(di + off)*4];
						var g = dstbytes[lasti*4+1] + dstbytes[(di + off)*4 + 5] - dstbytes[(di + off)*4+1];
						var b = dstbytes[lasti*4+2] + dstbytes[(di + off)*4 + 6] - dstbytes[(di + off)*4+2];
						clr = ((b & 0xFF) << 16) + ((g & 0xFF) << 8) + (r & 0xFF);
						dst[di] = clr; lasti = di; di++;                  						
					}
				case 5:
					while (n-->0) {
						clr = dst[di + off];  
						dst[di] = clr; di++;                  
					}
					lasti = di - 1;
			}			
			
			if (bpp == 16) {
				cx1 = (clr & 0xFF00) >> 2;
				cx = (clr >> 16);
			} else {
				cx1 = (clr & 0xFC00) >> 4;
				cx = clr >> 18;
			}
			
			/*if ((di & 0xFFFF0000) != last_di_segment) {//tmp
				last_di_segment = di & 0xFFFF0000;
				if (src.position - last_pos > 30000) {
					//?
					decoder_context = { di : di, ptype : ptype, src : src, buffer_addr : buffer_address, last_position : src.position };
					decoder_state = in_progress;
					return in_progress;
				}
			}*/
		}
		
		//prev_frame = buffer_address;
		prevFrame = dst;
		decoder_state = zero_state;
		decodedI = true;
		return zero_state;
	}
	
	public function ContinueI():DecoderState 
	{
		return DecompressI(decoder_context.src, decoder_context.dst);
	}
	
	public function DecompressP(src:Uint8Array, dst:Int32Array):PFrameResult 
	{
		//trace("SP decompressP sz=" + src.length + " bpp=" + bpp);
		if (src.length == 0 || !decodedI)
			return { data_pnt: prevFrame, significant_changes : false};
		//src.position = 0;
		var changes = src[0];// .readByte();
		if (changes == 0)
			return { data_pnt: prevFrame, significant_changes : false};

		/*if (src.length >= 10) {
			var s = "[";
			for (i in 0...10)
				s += src[i] + " ";
			Logging.MLog(s + "]");
		}*/
		//var pDst = buffer_address;
		//rc.DecodeBegin(src);
		ec.DecodeBegin(src, 1);

		var t = ec.decodeX(); //.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx1 = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx1 = (xx1<<8)+t;
		t = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx2 = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx2 = (xx2<<8)+t;

		//Logging.MLog("xx1=" +xx1 + " xx2=" + xx2 + " bts=" + bts.length);
		
		//decode block types		
		for (i in 0...bts.length) ///memset(bts,0,nbx*nby);
			bts[i] = 0;
		
		var x = xx1;
		while(x<=xx2) {
			var block_type = ec.decodeBT();//rc.DecodeVal(bttab, 5, SC_BTSTEP);
			var n = ec.decodeBN(); //rc.DecodeVal(ntab2, 256, SC_BTNSTEP);
			//trace("bts_i=" + x + " blocktype=" + block_type + " n=" + n);
			for(i in 0...n) {
				bts[x] = block_type;		
				x++;
			}
		}
		
		//are there significant changes?
		var signif = false;
		for (i in insignificant_blocks...bts.length)
			if (bts[i] > 0) {
				signif = true;
				break;
			}
	
		var stride = X; var clr = 0;
		//decode blocks
		var off = -X - 1;
		cx = cx1 = 0;
		var dstbytes = new Uint8Array( dst.buffer );
		//Logging.MLog("DecP main loop");
		for(by in 0...nby)
			for(bx in 0...nbx) {
				var y16 = by * 16; 
				var x16 = bx * 16; 
				var x1 = x16;
				var x2 = x16+16;
				var y1 = y16;
				var y2 = y16+16;
				if (x2>X) x2 = X;
				if (y2>Y) y2 = Y;				
				var bi = by * nbx + bx;
				
				if (bts[bi] > 0) {
					//Logging.MLog("bts[" + bi + "]=" + bts[bi]);
					if (((bts[bi] - 1) & 1) > 0) {
						//trace("((bts[bi] - 1) & 1) > 0");
						for(y in y1...y2) {
							var i = y*stride + x1;							
							for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[i], (x2-x1)*3);
								//Memory.setI32(pDst + i + x * 4, Memory.getI32(prev_frame + i + x * 4));
								dst[i + x] = prevFrame[i + x];
						}
						x1 = ec.decodeSXY(0) + x16; //rc.DecodeVal(sxytab[0], 16, SC_SXYSTEP);
						y1 = ec.decodeSXY(1) + y16; //rc.DecodeVal(sxytab[1], 16, SC_SXYSTEP);
						x2 = ec.decodeSXY(2) + x16 + 1;// rc.DecodeVal(sxytab[2], 16, SC_SXYSTEP);
						y2 = ec.decodeSXY(3) + y16 + 1; //rc.DecodeVal(sxytab[3], 16, SC_SXYSTEP);
						//Logging.MLog("x1=" + x1 + " y1=" + y1 + " x2=" + x2 + " y2=" + y2);
					}
				
					if (((bts[bi] - 1) & 2) > 0) { //motion vec
						//trace("((bts[bi] - 1) & 2) > 0");
						//trace("mvtab(0)=" + mvtab(0) + " msr_x=" + msr_x + " bytes_left=" + src.bytesAvailable);
						var mx = ec.decodeMX() - msr_x;// rc.DecodeVal(mvtab[0], msr_x*2, SC_MSTEP);		mx -= msr_x;
						var my = ec.decodeMY() - msr_y; //rc.DecodeVal(mvtab[1], msr_y*2, SC_MSTEP);	my -= msr_y;
						//Logging.MLog("mx=" + mx + " my=" + my);
						for(y in y1...y2) {
							var i = y * stride + x1;
							var j = (y + my) * stride + (x1 + mx);							
							for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[j], (x2-x1)*3);
								dst[i + x] = prevFrame[j + x];
								//Memory.setI32(pDst + i + x * 4, Memory.getI32(prev_frame + j + x * 4));
						}
					} else { //data
						x = x1; var y = y1; 
						var ptype = 0; var lastptype = 0;
						while(y < y2)  {
							///int r,g,b, i = y*stride + x*3;
							var i = y * stride + x;
							var di = i;// pDst + i;
							lastptype = ptype;
							ptype = ec.decodeP(lastptype);// rc.DecodeVal(ptypetab[lastptype], 6, SC_UNSTEP);
							//Logging.MLog("DecP (lastptype=" + lastptype + ") -> ptype=" + ptype);
							if (ptype == 0) {
								///pSrc = DecodeRGB(pSrc, r, g, b);					
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var r = ec.decodeClr(cx + cx1);
								MAKECX1();
								cx = r >> SC_CXSHIFT;
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var g = ec.decodeClr(4096 + cx+cx1);
								MAKECX1();
								cx = g >> SC_CXSHIFT;
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var b = ec.decodeClr(2*4096 + cx+cx1);
								MAKECX1();
								cx = b >> SC_CXSHIFT;		
								clr = (b << 16) + (g << 8) + r;								
								//Logging.MLog("rgb=" + r + " " +g + " " + b);
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
							}
						
							var n = ec.decodeN(ptype);//rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
							//Logging.MLog("DecN n=" + n);

							for(c in 0...n) {								
								switch(ptype) {
									case 1: clr = dst[di - 1];//Memory.getI32(di-4);  ///r = pDst[i-3]; g = pDst[i-2]; b = pDst[i-1];	
									case 2: clr = dst[di + off + 1];//Memory.getI32(di + off + 4); ///	r = pDst[i+off+3]; g = pDst[i+off+4]; b = pDst[i+off+5];					
									case 3: clr = prevFrame[i];//Memory.getI32(prev_frame + i);
									case 4:
										/*var r = Memory.getByte(di-4) + Memory.getByte(di + off + 4) - Memory.getByte(di + off);
										var g = Memory.getByte(di-3) + Memory.getByte(di + off + 5) - Memory.getByte(di + off+1);
										var b = Memory.getByte(di-2) + Memory.getByte(di + off + 6) - Memory.getByte(di + off+2);*/
										
										var r = dstbytes[(di-1)*4] + dstbytes[(di + off)*4 + 4] - dstbytes[(di + off)*4];
										var g = dstbytes[(di-1)*4+1] + dstbytes[(di + off)*4 + 5] - dstbytes[(di + off)*4+1];
										var b = dstbytes[(di-1)*4+2] + dstbytes[(di + off)*4 + 6] - dstbytes[(di + off)*4+2];
										
										clr = ((b & 0xFF) << 16) + ((g & 0xFF) << 8) + (r & 0xFF);
									case 5: clr = dst[di + off];//Memory.getI32(di + off);	///r = pDst[i+off]; g = pDst[i+off+1]; b = pDst[i+off+2];					
								}	
								//Memory.setI32(di, clr);
								dst[di] = clr;
								x++;
								if (x>=x2) {
									x = x1;
									y++;
									i = y * stride + x; di = i;
								} else {
									i += 1; di += 1; 
								}
							}//for c<n
							///cx = g>>SC_CXSHIFT;
							///MAKECX1;
							///cx = b>>SC_CXSHIFT;	
							if (bpp == 16) {
								cx1 = (clr & 0xFF00) >> 2;
								cx = clr >> 16;								
							} else {
								cx1 = (clr & 0xFC00) >> 4;
								cx = clr >> 18;
							}
							//Logging.MLog("cx=" + cx);
						}//while y<y2						
					}
				} else { //bts[] = 0
					for(y in y1...y2) {
						var i = y * stride + x1;						
						for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[i], (x2-x1)*3);
							dst[i + x] = prevFrame[i + x];
							//Memory.setI32(pDst + i + x * 4, Memory.getI32(prev_frame + i + x * 4));
					}
				}
			}//bx			
		//Logging.MLog("DecP main loop end");
		//prev_frame = buffer_address; //?
		prevFrame = dst;
		last_one_was_flat = null;
		return {data_pnt : prevFrame, significant_changes : signif};
	}
	
	public function NeedsIndex():Bool
	{
		return false;
	}
}