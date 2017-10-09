package ;
import RangeCoder;

import js.html.Uint8Array;
import js.html.Uint32Array;


class EntroCoderRC { 
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
	static inline var SC_CXMAX = 4096;
	static inline var SC_BTSTEP = 10; 
	static inline var SC_NCXMAX = 6;
	static inline var SC_BTNSTEP = 20;
	static inline var SC_SXYSTEP = 100; 
	static inline var SC_MSTEP = 100; 
	static inline var SC_UNSTEP = 1000; 
	static inline var SC_XXSTEP = 1;
	static inline var CNTABSZ = 273; 

	public function new() {
		rc = new RangeCoder();		
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
		mvtab[0] = new Uint32Array(ScreenPressor.msr_x*2 + 1);
		mvtab[1] = new Uint32Array(ScreenPressor.msr_y*2 + 1);	
	}
	
	public function preinit() {
		for (chan in 0...3)
			for (ctx in 0...SC_CXMAX) {
				cntab[((chan << 12) + ctx) * CNTABSZ + 16] = 0;
			}				
	}
	
	public function renewI() {
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
		var msr_x = ScreenPressor.msr_x;
		var msr_y = ScreenPressor.msr_y;
		
		for (i in 0...msr_x * 2)
			mvtab[0][i] = 1;//memset(mvtab(0), i, 1);
		mvtab[0][msr_x * 2] = msr_x * 2;//memset(mvtab(0), msr_x * 2, msr_x * 2);
		for (i in 0...msr_y * 2)
			mvtab[1][i] = 1;//memset(mvtab(1), i, 1);
		mvtab[1][msr_y * 2] = msr_y * 2; //memset(mvtab(1), msr_y * 2, msr_y * 2);				
	}
	
	public function DecodeBegin(src : Uint8Array, pos0 : Int):Void {
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
	
}//EntroCoderRC