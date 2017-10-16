package ;
import RangeCoder;
import ANS;
import js.Lib;
import js.html.Uint8Array;
import js.html.Uint32Array;

interface EntroCoder {
	function preinit():Void;
	function renewI():Void;
	function decodeBegin(src : Uint8Array, pos0 : Int):Void;
	function decodeClr(cxi:Int):Int;
	function decodeN(ptype:Int):Int;
	function decodeP(ptype:Int):Int;
	function decodeX():Int;
	function decodeBT():Int;
	function decodeBN():Int;
	function decodeSXY(n:Int):Int;
	function decodeMX():Int;
	function decodeMY():Int;	
	function canDecodeBool():Bool;
	function decodeBool():Bool;
}

class CC { //contexts consts
	public static inline var CXMAX = 4096;
	public static inline var NCXMAX = 6;	
}

class EntroCoderRC implements EntroCoder { 
	var rc : RangeCoder;

	var cntab : Uint32Array; 
	var ptypetab : Array<Uint32Array>;
	var ntab : Array<Uint32Array>;
	var xxtab : Uint32Array; //257
	var ntab2 : Uint32Array; //257
	var bttab : Uint32Array; //6
	var sxytab : Array<Uint32Array>; // 4 by 17
	var mvtab : Array<Uint32Array>; // msr_x*2, msr_y*2
	
	static inline var SC_STEP = 400;
	static inline var SC_NSTEP = 400;
	static inline var SC_BTSTEP = 10; 
	static inline var SC_BTNSTEP = 20;
	static inline var SC_SXYSTEP = 100; 
	static inline var SC_MSTEP = 100; 
	static inline var SC_UNSTEP = 1000; 
	static inline var SC_XXSTEP = 1;
	static inline var CNTABSZ = 273; 

	public function new() {
		rc = new RangeCoder();		
		cntab = new Uint32Array(3 * CC.CXMAX * CNTABSZ);
		ptypetab = new Array<Uint32Array>();
		ntab = new Array<Uint32Array>();
		for(i in 0...CC.NCXMAX) {
			ptypetab[i] = new Uint32Array(7);
			ntab[i] = new Uint32Array(257);
		}
		xxtab = new Uint32Array(257);
		ntab2 = new Uint32Array(257);
		bttab = new Uint32Array(6);
		sxytab = new Array<Uint32Array>();
		for (i in 0...4) sxytab[i] = new Uint32Array(17);
		mvtab = new Array<Uint32Array>();
		mvtab[0] = new Uint32Array(ScreenPressor.msr_x*2 + 1);
		mvtab[1] = new Uint32Array(ScreenPressor.msr_y*2 + 1);	
	}
	
	public function preinit():Void {
		for (chan in 0...3)
			for (ctx in 0...CC.CXMAX) {
				cntab[((chan << 12) + ctx) * CNTABSZ + 16] = 0;
			}				
	}
	
	public function renewI():Void {
		for (chan in 0...3)
			for (ctx in 0...CC.CXMAX) {
				var p = (chan * 4096 + ctx) * CNTABSZ;
				if (cntab[p + 16] != 256) { //fill if changed
					for(i in 0...256)
						cntab[p + i + 17] = 1;
					for(i in 0...16)
						cntab[p + i] = 16;
					cntab[p + 16] = 256;
				}				
			}
		for (ncx in 0...CC.NCXMAX) {
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
		var msr_x = ScreenPressor.msr_x;
		var msr_y = ScreenPressor.msr_y;
		
		for (i in 0...msr_x * 2)
			mvtab[0][i] = 1;//memset(mvtab(0), i, 1);
		mvtab[0][msr_x * 2] = msr_x * 2;//memset(mvtab(0), msr_x * 2, msr_x * 2);
		for (i in 0...msr_y * 2)
			mvtab[1][i] = 1;//memset(mvtab(1), i, 1);
		mvtab[1][msr_y * 2] = msr_y * 2; //memset(mvtab(1), msr_y * 2, msr_y * 2);				
	}
	
	public function decodeBegin(src : Uint8Array, pos0 : Int):Void {
		rc.DecodeBegin(src, pos0);
	}
	
	//var r = rc.DecodeValUni(cntab, (cx+cx1)*CNTABSZ, SC_STEP);
	public function decodeClr(cxi:Int):Int {
		return rc.DecodeValUni(cntab, cxi * CNTABSZ, SC_STEP);
	}
	
	//var n = rc.DecodeVal(ntab[0], 256, SC_NSTEP);
	public function decodeN(ptype:Int):Int {
		return rc.DecodeVal(ntab[ptype], 256, SC_NSTEP);
	}
	
	//ptype = rc.DecodeVal(ptypetab[ptype], 6, SC_UNSTEP);
	public function decodeP(ptype:Int):Int {
		return rc.DecodeVal(ptypetab[ptype], 6, SC_UNSTEP);
	}
	
	//var t = rc.DecodeVal(xxtab, 256, SC_XXSTEP);
	public function decodeX():Int {
		return rc.DecodeVal(xxtab, 256, SC_XXSTEP);
	}
	
	public function decodeBT():Int {
		return rc.DecodeVal(bttab, 5, SC_BTSTEP);
	}
	
	//var n = rc.DecodeVal(ntab2, 256, SC_BTNSTEP);
	public function decodeBN():Int {
		return rc.DecodeVal(ntab2, 256, SC_BTNSTEP);
	}
	
	//y2 = rc.DecodeVal(sxytab[3], 16, SC_SXYSTEP);
	public function decodeSXY(n:Int):Int {
		return rc.DecodeVal(sxytab[n], 16, SC_SXYSTEP);
	}
	
	//var my = rc.DecodeVal(mvtab[1], msr_y*2, SC_MSTEP);
	public function decodeMX():Int {
		return rc.DecodeVal(mvtab[0], ScreenPressor.msr_x*2, SC_MSTEP);
	}	
	public function decodeMY():Int {
		return rc.DecodeVal(mvtab[1], ScreenPressor.msr_y*2, SC_MSTEP);
	}
	
	public function canDecodeBool() { return false; }	
	public function decodeBool():Bool { return false;  }
}//EntroCoderRC

class EntroCoderANS extends DecReceiver implements EntroCoder {
	var rans : Rans;
	var nDec : Int;
	var cntab : Array<Context>; 
	var ptypetab : Array<FixedSizeRansCtx>; //[6] (6)
	var ntab : Array<FixedSizeRansCtx>; //[6] (256)
	var xxtab : FixedSizeRansCtx; //(256)
	var ntab2 : FixedSizeRansCtx; //(256)
	var bttab : FixedSizeRansCtx; //(5)
	var sxytab : Array<FixedSizeRansCtx>; // [4]  (16)
	var mvtab : Array<FixedSizeRansCtx>; // [2] (512)
	
	public function new() {
		super();
		cntab = new Array<Context>();
		for (i in 0 ... CC.CXMAX * 3) cntab[i] = new Context();
		ntab = new Array<FixedSizeRansCtx>();
		for (i in 0 ... CC.NCXMAX)	ntab[i] = new FixedSizeRansCtx(256);
		ptypetab = new Array<FixedSizeRansCtx>();
		for (i in 0...6) ptypetab[i] = new FixedSizeRansCtx(6);
		xxtab = new FixedSizeRansCtx(256);
		ntab2 = new FixedSizeRansCtx(256);
		bttab = new FixedSizeRansCtx(5);
		sxytab = new Array<FixedSizeRansCtx>();
		for (i in 0...4) sxytab[i] = new FixedSizeRansCtx(16);
		mvtab = new Array<FixedSizeRansCtx>();
		for (i in 0...2) mvtab[i] = new FixedSizeRansCtx(512);
	}
	
	public function preinit():Void {}
	
	public function renewI():Void {
		for (i in 0... CC.CXMAX * 3)
			cntab[i].renew();
		for (i in 0 ... CC.NCXMAX)
			ntab[i].renew();
		for (i in 0...6) ptypetab[i].renew();
		xxtab.renew();
		ntab2.renew();
		bttab.renew();
		for (i in 0...4) sxytab[i].renew();
		for (i in 0...2) mvtab[i].renew();
	}
	
	public function decodeBegin(src : Uint8Array, pos0 : Int):Void {
		trace("decodeBegin pos0="+pos0 + " src.len=" + src.length);
		rans = new Rans(src, pos0);
		nDec = 0;
	}
	
	public function decodeClr(cxi:Int):Int {
		var dcx = cntab[cxi];
		var c : Int;// = 0;
		
		//dbg
		if (cxi == 3380) { 
			Logging.MLog("decodeClr(3380): someFreq=" + rans.decGet());
			dcx.show();
		}
		
		if (dcx.decode(rans.decGet())) {
			c = dcx.c;
			if (c > 255) Lib.debug();
			rans.decAdvance(dcx.cumFreq, dcx.freq);
		} else {
			c = rans.raw();
			if (c > 255) Lib.debug();
			dcx.update(c);
		}
		nDec++;
		if (nDec == Rans.B) {
			rans.reinit();
			nDec = 0;
		}
		return c;
	}
	
	public function canDecodeBool() { return true; }
	
	public function decodeBool():Bool {
		var f = rans.decGet();
		var flag : Bool = f >= Rans.PROB_SCALE >> 1;
		rans.decAdvance( (flag ? Rans.PROB_SCALE >> 1 : 0) , Rans.PROB_SCALE >> 1);
		nDec++;
		if (nDec==Rans.B) {
			rans.reinit();
			nDec = 0;
		}
		return flag;		
	}	
	
	function decodeF(dcx:FixedSizeRansCtx):Int {
		dcx.decode( rans.decGet(), this);
		rans.decAdvance(cumFreq, freq);
		nDec++;
		if (nDec == Rans.B) {
			rans.reinit();
			nDec = 0;
		}
		return c;
	}
	
	public function decodeN(ptype:Int):Int {
		return decodeF(ntab[ptype]);
	}
	
	public function decodeP(ptype:Int):Int {
		return decodeF(ptypetab[ptype]);
	}
	
	public function decodeX():Int {
		return decodeF(xxtab);
	}
	
	public function decodeBT():Int {
		return decodeF(bttab);
	}
	
	public function decodeBN():Int {
		return decodeF(ntab2);
	}
	
	public function decodeSXY(n:Int):Int {
		return decodeF(sxytab[n]);
	}
	
	public function decodeMX():Int {
		return decodeF(mvtab[0]);
	}
	
	public function decodeMY():Int {
		return decodeF(mvtab[1]);
	}
	
}//EntroCoderANS