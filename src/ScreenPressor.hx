package ;
import openfl.Memory;
import openfl.utils.ByteArray;
import openfl.Vector;
import RangeCoder;
import openfl.utils.Endian;
import IVideoCodec;
import js.html.Int32Array;
import js.html.Uint8Array;
import js.html.Uint32Array;
import js.Lib as JsLib;

typedef DecoderContext = {
	var di : Int;
	var ptype : Int;
	var src : Uint8Array;
	var dst : Int32Array;
	var last_position : Int; // pos in src
}

class ScreenPressor implements IVideoCodec
{
	static inline var SC_STEP = 400;
	static inline var SC_NSTEP = 400;
	              var SC_CXSHIFT : Int;
	static inline var SC_CXMAX = 4096;
	static inline var SC_BTSTEP = 10; 
	static inline var SC_NCXMAX = 6;
	static inline var SC_BTNSTEP = 20;
	static inline var SC_SXYSTEP = 100; 
	static inline var SC_MSTEP = 100; 
	static inline var SC_UNSTEP = 1000; 
	static inline var SC_XXSTEP = 1;
	static inline var CNTABSZ = 273; 
	
	static inline var msr_x = 256; //motion search ranges 
	static inline var msr_y = 256;
	static inline var msrlow_x = 8;
	static inline var msrlow_y = 8; 

	var cx : Int;
	var cx1 : Int;
	var X : Int;
	var Y : Int;
	var rc : RangeCoder;
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
	
	/*static inline function mem(arr:Int, idx:Int):Int
	{
		return Memory.getI32(arr + (idx << 2));
	}
	
	static inline function memset(arr:Int, idx:Int, val:Int):Void
	{
		Memory.setI32(arr + (idx << 2), val);
	}*/


	///uint *cntab[3][SC_CXMAX];
	var cntab : Uint32Array; 
	var ptypetab : Array<Uint32Array>;
	var ntab : Array<Uint32Array>;

	/*inline function cntab(channel:Int, context:Int):Int //returns pointer in Memory
	{
		return ((channel << 12) + context) * 1092; //4 * (273 == 16 + 1 + 256)
	}
	
	static inline var addr_ntab = 13418496; // 3 * 4096 * 273 * 4
	///uint *ntab[SC_NCXMAX]
	static inline function ntab(context:Int):Int
	{
		return addr_ntab + context * 1028; //4 * (256 + 1)
	}
	
	static inline var addr_ptypetab = addr_ntab + 6 * 1028;
	static inline function ptypetab(context:Int):Int
	{
		return addr_ptypetab + context * 28;
	}*/
	
	//static inline var un = addr_ptypetab + 6 * 28;	//not used!
	var xxtab : Uint32Array; //257
	var ntab2 : Uint32Array; //257
	var bttab : Uint32Array; //6
	var sxytab : Array<Uint32Array>; // 4 by 17
	var mvtab : Array<Uint32Array>; // msr_x*2, msr_y*2
	
	/*static inline var xxtab = un + 28;
	static inline var ntab2 = xxtab + 257 * 4;
	static inline var bttab = ntab2 + 257 * 4;
	static inline var addr_sxytab = bttab + 6 * 4;
	static inline function sxytab(context:Int):Int
	{
		return addr_sxytab + context * 68; //17*4
	}
	
	static inline var addr_mvtab = addr_sxytab + 17 * 4 * 4;
	static inline function mvtab(context:Int):Int
	{
		return addr_mvtab + (msr_x * 2 + 1) * 4 * context;
	}*/
	
	static inline var addr_end_tables = 0;// addr_mvtab + (msr_x * 2 + 1  + msr_y * 2 + 1) * 4;
	
	public function new(width:Int, height:Int, num_buffers:Int, bits_per_pixel:Int) //num_frames - number of decompressed frames to store in memory
	{
		//trace("ScreenPressor.new: bpp=" + bits_per_pixel + " w=" + width + " h=" + height);
		X = width; Y = height; bpp = bits_per_pixel;
		rc = new RangeCoder();
		decoder_state = zero_state;
		decoder_context = null;
		nbx = Std.int((X + 15) / 16);
		nby = Std.int((Y + 15) / 16);
		bts = new Vector(nbx * nby);		
		SC_CXSHIFT = bpp == 16 ? 0 : 2;		
		decodedI = false;
		//prev_frame = 0;
		
		cntab = new Uint32Array(3 * 4096 * CNTABSZ);
		ptypetab = new Array<Uint32Array>();
		ntab = new Array<Uint32Array>();
		for(i in 0...6) {
			ptypetab[i] = new Uint32Array(7);
			ntab[i] = new Uint32Array(257);
		}
		xxtab = new Uint32Array(257);
		ntab2 = new Uint32Array(257);
		bttab = new Uint32Array(6);
		sxytab = new Array<Uint32Array>();
		for (i in 0...4) sxytab[i] = new Uint32Array(17);
		mvtab = new Array<Uint32Array>();
		mvtab[0] = new Uint32Array(msr_x*2 + 1);
		mvtab[1] = new Uint32Array(msr_y*2 + 1);
	}
	
	public function StopAndClean():Void
	{
		bts = null; rc = null;
	}
	
	public function Preinit(insignificant_lines : Int):Void //must be called after memory is allocated
	{
		//trace("SP.Preinit");
		for (chan in 0...3)
			for (ctx in 0...SC_CXMAX) {
				cntab[((chan << 12) + ctx) * CNTABSZ + 16] = 0;
			}		
		insignificant_blocks = nbx * Std.int((insignificant_lines + 15) / 16);
		insign_lines = insignificant_lines;
	}
	
	/*public function BufferStartAddr():Int
	{
		return addr_end_tables;
	}*/
	
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
						
		for (chan in 0...3)
			for (ctx in 0...SC_CXMAX) {
				var p = (chan * 4096 + ctx) * CNTABSZ;
				if (cntab[p + 16] != 256) { //fill if changed
					for(i in 0...256)
						cntab[p + i + 17] = 1;
					for(i in 0...16)
						cntab[p + i] = 16;
					cntab[p + 16] = 256;
				}				
			}
		for (ncx in 0...SC_NCXMAX) {
			var p = ntab[ncx];
			for(i in 0...256)
				p[i] = 1;
			p[256] = 256;      
		}
		
		for (ctx in 0...6) {
			var p = ptypetab[ctx];
			for(i in 0...6)
				p[i] = 1;
			p[6] = 6;			
		}				
		
		for (i in 0...256) {
			xxtab[i] = 1; ntab2[i] = 1;
		}
		xxtab[256] = 256; ntab2[256] = 256;
		
		for (i in 0...5)
			bttab[i] = 1;//memset(bttab, i, 1);
		bttab[5] = 5;//memset(bttab, 5, 5);
		
		for (ctx in 0...4) {
			for (i in 0...16)
				sxytab[ctx][i] = 1;//memset(sxytab(ctx), i, 1);
			sxytab[ctx][16] = 16;//memset(sxytab(ctx), 16, 16);
		}
		
		for (i in 0...msr_x * 2)
			mvtab[0][i] = 1;//memset(mvtab(0), i, 1);
		mvtab[0][msr_x * 2] = msr_x * 2;//memset(mvtab(0), msr_x * 2, msr_x * 2);
		for (i in 0...msr_y * 2)
			mvtab[1][i] = 1;//memset(mvtab(1), i, 1);
		mvtab[1][msr_y * 2] = msr_y * 2; //memset(mvtab(1), msr_y * 2, msr_y * 2);		
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
			rc.DecodeBegin(src, 1);

			cx = cx1 = 0;
			var k = 0; 
			
			lasti = di;
			while(k<X+1) {
				var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = r>>SC_CXSHIFT;
				var g = rc.DecodeValUni(cntab, (4096 + cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = g>>SC_CXSHIFT;
				var b = rc.DecodeValUni(cntab, (2*4096 + cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = b>>SC_CXSHIFT;			
			
				var n = rc.DecodeVal(ntab[0], 256, SC_NSTEP);
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
			/*ptype = rc.DecodeVal(ptypetab(ptype), 6, SC_UNSTEP, src);
			if (ptype==0) {
				///pSrc = DecodeRGB(pSrc, r, g, b);	
				var r = rc.DecodeValUni(cntab(0, cx + cx1), SC_STEP, src);
				MAKECX1();
				cx = r >> SC_CXSHIFT;
				var g = rc.DecodeValUni(cntab(1, cx + cx1), SC_STEP, src);
				MAKECX1();
				cx = g >> SC_CXSHIFT;
				var b = rc.DecodeValUni(cntab(2, cx + cx1), SC_STEP, src);
				MAKECX1();
				cx = b >> SC_CXSHIFT;		
				clr = (b << 16) + (g << 8) + r;
			}			
			var n = rc.DecodeVal(ntab(ptype), 256, SC_NSTEP, src);*/
			ptype = rc.DecodeVal(ptypetab[ptype], 6, SC_UNSTEP);
			if (ptype==0) {
				var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = r >> SC_CXSHIFT;
				var g = rc.DecodeValUni(cntab, (4096 + cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = g >> SC_CXSHIFT;
				var b = rc.DecodeValUni(cntab, (2*4096 + cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = b >> SC_CXSHIFT;		
				clr = (b << 16) + (g << 8) + r;
			}			
			var n = rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);

			/*for(j in 0...n) {
				switch(ptype) {
					case 1: clr = Memory.getI32(lasti);  ///r = pDst[lasti]; g = pDst[lasti+1]; b = pDst[lasti+2];					
					case 2: clr = Memory.getI32(di + off + 4); ///	r = pDst[i+off+3]; g = pDst[i+off+4]; b = pDst[i+off+5];					
					case 4:
						var r = Memory.getByte(lasti) + Memory.getByte(di + off + 4) - Memory.getByte(di + off);
						var g = Memory.getByte(lasti+1) + Memory.getByte(di + off + 5) - Memory.getByte(di + off+1);
						var b = Memory.getByte(lasti+2) + Memory.getByte(di + off + 6) - Memory.getByte(di + off+2);
						clr = ((b & 0xFF) << 16) + ((g & 0xFF) << 8) + (r & 0xFF);
					case 5: clr = Memory.getI32(di + off);	///r = pDst[i+off]; g = pDst[i+off+1]; b = pDst[i+off+2];					
				}	
				Memory.setI32(di, clr);
				lasti = di;
				di += 4;			
			}*/
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
		//Logging.MLog("SP decompressP sz=" + src.length + " bpp=" + bpp);
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
		rc.DecodeBegin(src, 1);

		//var n = rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
		var t = rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx1 = rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx1 = (xx1<<8)+t;
		t = rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx2 = rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx2 = (xx2<<8)+t;

		//Logging.MLog("xx1=" +xx1 + " xx2=" + xx2 + " bts=" + bts.length);
		
		//decode block types		
		for (i in 0...bts.length) ///memset(bts,0,nbx*nby);
			bts[i] = 0;
		
		var x = xx1;
		while(x<=xx2) {
			var block_type = rc.DecodeVal(bttab, 5, SC_BTSTEP);
			var n = rc.DecodeVal(ntab2, 256, SC_BTNSTEP);
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
						x1 = rc.DecodeVal(sxytab[0], 16, SC_SXYSTEP);
						x1 += x16;
						y1 = rc.DecodeVal(sxytab[1], 16, SC_SXYSTEP);
						y1 += y16;
						x2 = rc.DecodeVal(sxytab[2], 16, SC_SXYSTEP);
						x2 += x16+1;
						y2 = rc.DecodeVal(sxytab[3], 16, SC_SXYSTEP);
						y2 += y16 + 1;
						//Logging.MLog("x1=" + x1 + " y1=" + y1 + " x2=" + x2 + " y2=" + y2);
					}
				
					if (((bts[bi] - 1) & 2) > 0) { //motion vec
						//trace("((bts[bi] - 1) & 2) > 0");
						//trace("mvtab(0)=" + mvtab(0) + " msr_x=" + msr_x + " bytes_left=" + src.bytesAvailable);
						var mx = rc.DecodeVal(mvtab[0], msr_x*2, SC_MSTEP);
						mx -= msr_x;
						var my = rc.DecodeVal(mvtab[1], msr_y*2, SC_MSTEP);
						my -= msr_y;
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
							ptype = rc.DecodeVal(ptypetab[lastptype], 6, SC_UNSTEP);
							//Logging.MLog("DecP (lastptype=" + lastptype + ") -> ptype=" + ptype);
							if (ptype == 0) {
								//JsLib.debug();
								///pSrc = DecodeRGB(pSrc, r, g, b);					
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
								MAKECX1();
								cx = r >> SC_CXSHIFT;
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var g = rc.DecodeValUni(cntab, (4096 + cx+cx1)*CNTABSZ, SC_STEP);
								MAKECX1();
								cx = g >> SC_CXSHIFT;
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
								var b = rc.DecodeValUni(cntab, (2*4096 + cx+cx1)*CNTABSZ, SC_STEP);
								MAKECX1();
								cx = b >> SC_CXSHIFT;		
								clr = (b << 16) + (g << 8) + r;								
								//Logging.MLog("rgb=" + r + " " +g + " " + b);
								//Logging.MLog("cx=" + cx+ " cx1=" + cx1);
							}
						
							var n = rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
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