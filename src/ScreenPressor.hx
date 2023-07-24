package ;
import js.Browser;
import js.lib.Int32Array;
import js.lib.Uint8Array;
import js.lib.Uint32Array;
import js.Lib as JsLib;
import js.html.Performance;
import EntroCoders;
import IVideoCodec;

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
	var ec : EntroCoder;
    var SC_CXSHIFT : Int;
	var X : Int;
	var Y : Int;
	var prevFrame : Int32Array;
	//var prev_frame : Int; //pointer
	var nbx : Int;
	var nby : Int;
	var bts: Int32Array;
	var bpp : Int;
	var decoder_state : DecoderState;
	var decoder_context : DecoderContext;
	var insignificant_blocks : Int;
	var decodedI : Bool;
	var last_one_was_flat : Null<Int>;
	var decodingBools : Bool;

	inline function MAKECX1():Void
	{
		cx1 = (cx << 6) & 0xFC0;
	}


	static inline var addr_end_tables = 0;// addr_mvtab + (msr_x * 2 + 1  + msr_y * 2 + 1) * 4;

	public function new(width:Int, height:Int, bits_per_pixel:Int)
	{
		//trace("ScreenPressor.new: bpp=" + bits_per_pixel + " w=" + width + " h=" + height);
		X = width; Y = height; bpp = bits_per_pixel;
		decoder_state = zero_state;
		decoder_context = null;
		SC_CXSHIFT = bpp == 16 ? 0 : 2;
		nbx = Std.int((X + 15) / 16);
		nby = Std.int((Y + 15) / 16);
		bts = new Int32Array(nbx * nby);
		decodedI = false;
	}

	function initEntro(version:Int):Bool { // => ok?
		trace("ScreenPressor stream version=" + version);
		switch(version) {
			case 2: ec = new EntroCoderRC();
			case 3: ec = new EntroCoderANS(64);
			        SC_CXSHIFT = 2; //v3 handles 16bpp pretty much like 24bpp
            case 4: ec = new EntroCoderANS(32);
			        SC_CXSHIFT = 2;
			default: trace("unknown version of ScreenPressor!"); return false;
		}
		decodingBools = ec.canDecodeBool();
		ec.preinit();
		return true;
	}

	public function StopAndClean():Void
	{
		bts = null; ec = null; prevFrame = null; //cntab = null;
	}

	public function Preinit(insignificant_lines : Int):Void //must be called after memory is allocated
	{
		insignificant_blocks = nbx * Std.int((insignificant_lines + 15) / 16);
	}

	public function PreviousFrame():Int32Array
	{
		return prevFrame;
	}

	public function IsKeyFrame(data : Uint8Array):Bool
	{
		if (data == null || data.length == 0) return false;
		var b = data[0];
		return (b == 0x12 || b == 0x11 || b == 0x22 || b == 0x21|| b == 0x32 || b == 0x31);
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
		var maskcx1 = 0xFC00, shiftcx1 = 4, shiftcx = 18;

		Logging.MLog("SP.DecompressI src.size=" + src.length + " bpp=" + bpp + " rnd=" + Math.random());
		//Logging.on = false;

		var t0 = Browser.window.performance.now();

		if (decoder_state == zero_state) {
			//src.position = 0;

			var head = src[0];// .readByte();
			var version = (head >> 4) + 1;
			if ((head & 0xF) == 1) { //flat
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
			if ((head & 0xF) != 2) {
				trace("unknown version of the codec"); return error_occured;
			}
			if (ec == null) {
				if (!initEntro(version)) return error_occured;
			}
			RenewI();
			ec.decodeBegin(src, 1);

			cx = cx1 = 0;
			var k = 0;

			lasti = di;
			while(k<X+1) {
				//var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				//Logging.dbg("cx="+cx + " cx1="+cx1);
				var r = ec.decodeClr(cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = r >> SC_CXSHIFT;
				//Logging.dbg("cx="+cx + " cx1="+cx1);
				var g = ec.decodeClr(4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = g >> SC_CXSHIFT;
				//Logging.dbg("cx="+cx + " cx1="+cx1);
				var b = ec.decodeClr(2*4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = b >> SC_CXSHIFT;
				//Logging.dbg("cx=" + cx + " cx1=" + cx1);
				//Logging.dbg("rgb=" + r + "," + g + "," + b);

				var n = ec.decodeN(0); //rc.DecodeVal(ntab[0], 256, SC_NSTEP);
				//Logging.dbg("n=" + n);
				clr = (b << 16) + (g << 8) + r;
				k += n;
				while(n-->0) {
					dst[di] = clr;
					di++;
				}
				lasti = di - 1;

			}
		} //if zero_state

		if (bpp == 16 && ec.differentConstantsFor16bbp()) {
			maskcx1 = 0xFF00; shiftcx1 = 2; shiftcx = 16;
		}


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
		//Logging.dbg("main loop");
		while (di < end) {
			var lastptype = ptype;
			ptype = ec.decodeP(ptype);//rc.DecodeVal(ptypetab[ptype], 6, SC_UNSTEP);
			//Logging.dbg("decodeP("+lastptype+") => "+ptype);
			if (ptype == 0) {
				//Logging.dbg("cx=" + cx + " cx1=" + cx1);
				var r = ec.decodeClr(cx + cx1);//rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
				cx1 = (cx<<6)&0xFC0;
				cx = r >> SC_CXSHIFT;
				//Logging.dbg("cx=" + cx + " cx1=" + cx1);
				var g = ec.decodeClr(4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = g >> SC_CXSHIFT;
				//Logging.dbg("cx=" + cx + " cx1=" + cx1);
				var b = ec.decodeClr(2*4096 + cx+cx1);
				cx1 = (cx<<6)&0xFC0;
				cx = b >> SC_CXSHIFT;
				clr = (b << 16) + (g << 8) + r;
				//Logging.dbg("cx=" + cx + " cx1=" + cx1);
				//Logging.dbg("rgb=" + r + "," + g + "," + b);
			}
			var n = ec.decodeN(ptype); //rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
			//Logging.dbg("n="+n);

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
			cx1 = (clr & maskcx1) >> shiftcx1;
			cx = clr >> shiftcx;

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
		var t1 = Browser.window.performance.now();
		Logging.MLog(" DecompressI time = " + (t1 - t0));
		//Logging.on = true;
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
		//var t0 = Browser.window.performance.now();
        last_one_was_flat = null;

		if (src.length == 0 || !decodedI)
			return { data_pnt: prevFrame, significant_changes : false};

		var changes = src[0];
		if (changes == 0)
			return { data_pnt: prevFrame, significant_changes : false};

		var maskcx1 = 0xFC00, shiftcx1 = 4, shiftcx = 18;
		if (ec.differentConstantsFor16bbp() && bpp == 16) {
			maskcx1 = 0xFF00; shiftcx1 = 2; shiftcx = 16;
		}

		ec.decodeBegin(src, 1);

		var t = ec.decodeX(); //.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx1 = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx1 = (xx1<<8)+t;
		t = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		var xx2 = ec.decodeX(); // rc.DecodeVal(xxtab, 256, SC_XXSTEP);
		xx2 = (xx2<<8)+t;

		//Logging.dbg("xx1=" +xx1 + " xx2=" + xx2 + " bts=" + bts.length);

		//decode block types
		for (i in 0...bts.length) ///memset(bts,0,nbx*nby);
			bts[i] = 0;

		var x = xx1;
		while(x<=xx2) {
			var block_type = ec.decodeBT();//rc.DecodeVal(bttab, 5, SC_BTSTEP);
			var n = ec.decodeBN(); //rc.DecodeVal(ntab2, 256, SC_BTNSTEP);
			//Logging.dbg("bts_i=" + x + " blocktype=" + block_type + " n=" + n);
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
		var lastmx = 0, lastmy = 0;
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
					//Logging.dbg("bts[" + bi + "]=" + bts[bi]);
					if (((bts[bi] - 1) & 1) > 0) {
						for(y in y1...y2) {
							var i = y*stride + x1;
							for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[i], (x2-x1)*3);
								dst[i + x] = prevFrame[i + x];
						}
						x1 = ec.decodeSXY(0) + x16; //rc.DecodeVal(sxytab[0], 16, SC_SXYSTEP);
						y1 = ec.decodeSXY(1) + y16; //rc.DecodeVal(sxytab[1], 16, SC_SXYSTEP);
						x2 = ec.decodeSXY(2) + x16 + 1;// rc.DecodeVal(sxytab[2], 16, SC_SXYSTEP);
						y2 = ec.decodeSXY(3) + y16 + 1; //rc.DecodeVal(sxytab[3], 16, SC_SXYSTEP);
						//Logging.dbg("x1=" + x1 + " y1=" + y1 + " x2=" + x2 + " y2=" + y2);
					}

					if (((bts[bi] - 1) & 2) > 0) { //motion vec
						//trace("((bts[bi] - 1) & 2) > 0");
						//trace("mvtab(0)=" + mvtab(0) + " msr_x=" + msr_x + " bytes_left=" + src.bytesAvailable);
						var mx : Int, my : Int;
						if (decodingBools && ec.decodeBool()) {
							mx = lastmx; my = lastmy;
						} else {
							mx = ec.decodeMX() - msr_x;// rc.DecodeVal(mvtab[0], msr_x*2, SC_MSTEP);		mx -= msr_x;
							my = ec.decodeMY() - msr_y; //rc.DecodeVal(mvtab[1], msr_y*2, SC_MSTEP);	my -= msr_y;
						}
						lastmx = mx; lastmy = my;
						//Logging.dbg("mx=" + mx + " my=" + my);
						for(y in y1...y2) {
							var i = y * stride + x1;
							var j = (y + my) * stride + (x1 + mx);
							for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[j], (x2-x1)*3);
								dst[i + x] = prevFrame[j + x];
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
							//Logging.dbg("DecP (lastptype=" + lastptype + ") -> ptype=" + ptype);
							if (ptype == 0) {
								///pSrc = DecodeRGB(pSrc, r, g, b);
								//Logging.dbg("cx=" + cx+ " cx1=" + cx1);
								var r = ec.decodeClr(cx + cx1);
								MAKECX1();
								cx = r >> SC_CXSHIFT;
								//Logging.dbg("cx=" + cx+ " cx1=" + cx1);
								var g = ec.decodeClr(4096 + cx+cx1);
								MAKECX1();
								cx = g >> SC_CXSHIFT;
								//Logging.dbg("cx=" + cx+ " cx1=" + cx1);
								var b = ec.decodeClr(2*4096 + cx+cx1);
								MAKECX1();
								cx = b >> SC_CXSHIFT;
								clr = (b << 16) + (g << 8) + r;
								//Logging.dbg("rgb=" + r + " " +g + " " + b);
								//Logging.dbg("cx=" + cx+ " cx1=" + cx1);
							}

							var n = ec.decodeN(ptype);//rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
							//Logging.dbg("DecN n=" + n);

							for(c in 0...n) {
								switch(ptype) {
									case 1: clr = dst[di - 1];//Memory.getI32(di-4);  ///r = pDst[i-3]; g = pDst[i-2]; b = pDst[i-1];
									case 2: clr = dst[di + off + 1];//Memory.getI32(di + off + 4); ///	r = pDst[i+off+3]; g = pDst[i+off+4]; b = pDst[i+off+5];
									case 3: clr = prevFrame[i];//Memory.getI32(prev_frame + i);
									case 4:
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
							cx1 = (clr & maskcx1) >> shiftcx1;
							cx = clr >> shiftcx;

							//Logging.dbg("cx=" + cx + " cx1=" + cx1);
						}//while y<y2
					}
				} else { //bts[] = 0
					for(y in y1...y2) {
						var i = y * stride + x1;
						for (x in 0...(x2 - x1)) ///memcpy(&pDst[i], &prev[i], (x2-x1)*3);
							dst[i + x] = prevFrame[i + x];
					}
				}
			}//bx
		//Logging.dbg("DecP main loop end");
		//var t1 = Browser.window.performance.now();
		//Logging.MLog(" DecompressP time = " + (t1 - t0));

		//prev_frame = buffer_address; //?
		prevFrame = dst;
		//Logging.on = false;
		return {data_pnt : prevFrame, significant_changes : signif};
	}

	public function NeedsIndex():Bool
	{
		return false;
	}
}