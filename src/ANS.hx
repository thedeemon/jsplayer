package ;
import js.lib.Uint16Array;
import js.lib.Uint8Array;

class Rans {
	var r : Int;
	var pos : Int;
	var data : Uint8Array;

	public static inline var B = 131072;
	public static inline var PROB_SCALE = 4096;


	public function new(srcdata:Uint8Array, pos0 : Int = 0):Void {
		reinitImpl(srcdata, pos0);
	}

	public function reinit():Void {
		reinitImpl(data, pos);
	}

	function reinitImpl(srcdata:Uint8Array, i:Int):Void {
		//trace("Rans.start at "+i);
		data = srcdata;
		var x = data[i+0];
		x |= data[i+1] << 8;
		x |= data[i+2] << 16;
		x |= data[i+3] << 24;
		r = x;
		pos = i+4;
	}

	static inline var RANS_BYTE_L = 1 << 23;

	public inline function decGet():Int { return r & 4095; }

	public function decAdvance(start:Int, freq:Int):Void {
		var x = r;
		x = freq * (x >> 12) + (x & 4095) - start;
		while (x < RANS_BYTE_L) {
			x = (x << 8) | data[pos++];
		}
		r = x;
	}

	public inline function raw() : Int {
		return data[pos++];
	}
}//class Rans

//Interval for symbol encoding by an entropy coder. [cumFreq, cumFreq + freq)
typedef Freq = { freq : Int, cumFreq : Int } //to pass byte without compressing: freq=0, cumFreq=c

class FixedSizeRansCtx {
	static inline var STEP_FX = 16;
	static inline var step = STEP_FX;
	static inline var Dshift = 7;
	static inline var D = 1 << Dshift;

	var freqs : Uint16Array;
	public var cnts : Uint16Array;
	var cntsum:Int;
	//var cxdata: BigContext; // Nsym * 6 bytes, 1.5k for NSym=256
	//BYTE decTable[PROB_SCALE / D]; //32 bytes for current values of PROB_SCALE=4k and Dshift=7
	var decTable : Uint8Array;
	var NSym : Int;

	public function new(NSymb:Int) {
		NSym = NSymb;
		freqs = new Uint16Array(NSymb * 2);
		cnts = new Uint16Array(NSymb);
		decTable = new Uint8Array(32);
	}

	public inline function setFreq(i:Int, fr:Int, cf:Int) {
		freqs[i * 2] = fr; freqs[i * 2 + 1] = cf;
	}

	inline function readFreq(i:Int) { return freqs[i * 2]; }
	inline function readCumFreq(i:Int) { return freqs[i * 2 + 1]; }

	public inline function getCumFreq(i:Int) { return freqs[i * 2 + 1]; }


	function incrCnt(c:Int):Void {
		//assert(c >= 0);
		//assert(c < NSym);
		cnts[c] += step; cntsum += step;
		if (cntsum + step > Rans.PROB_SCALE) {
			cntsum = 0; var cf = 0;
			for(j in 0...NSym) {
				var fr =  cnts[j];
				setFreq(j, fr, cf);
				var k0:Int = (cf + D-1) >> Dshift;//first z >= cf, such that z = 8*k
				var k1:Int = ((cf + fr - 1) >> Dshift) + 1;
				for(k in k0...k1)
					decTable[k] = j;
				cf += fr;
				cnts[j] -= fr >> 1;
				cntsum += cnts[j];
			}
		}
	}

	public function decode(someFreq:Int, rcv:DecReceiver):Bool { // => always true
		//public function de(someFreq:Int, interval:Freq):Int {
		//assert(someFreq >= 0);
		//assert(someFreq < PROB_SCALE);
		var c0 = decTable[someFreq >> Dshift];
		//assert(c0 >= 0);
		//assert(c0 < NSym);
		for(j in c0...NSym-1) {
			//assert(cxdata.freqs[j].cumFreq <= someFreq); //should be true by design
			//assert(cxdata.freqs[j].cumFreq + cxdata.freqs[j].freq == cxdata.freqs[j+1].cumFreq);
			if (getCumFreq(j+1) > someFreq) {
				rcv.freq = readFreq(j); rcv.cumFreq = readCumFreq(j); rcv.c = j;
				incrCnt(j);
				return true;
			}
		}
		//if we're here then c = last symbol
		rcv.freq = readFreq(NSym - 1); rcv.cumFreq = readCumFreq(NSym - 1);
		rcv.c = NSym - 1;
		incrCnt(NSym-1);
		return true;
	}

	public function renew():Void { //set equal probs
		var cf = 0;
		var fr : Int = Std.int(Rans.PROB_SCALE / NSym);
		var c0 : Int = fr - (fr >> 1);
		cntsum = c0 * NSym;
		for(i in 0...NSym) {
			//cxdata.freqs[i].freq = fr;
			//cxdata.freqs[i].cumFreq = cf;
			setFreq(i, fr, cf);
			cnts[i] = c0;
			var k0 = (cf + D-1) >> Dshift;//first z >= cf, such that z = 8*k
			var k1 = ((cf + fr - 1) >> Dshift) + 1;
			for(k in k0...k1)
				decTable[k] = i;
			cf += fr;
		}
	}
}

enum FindRes { Found; Added; NoRoom; }

typedef DecReceiver = {
	var c : Int; //decoded
	var freq : Int;
	var cumFreq : Int;
}

class SymbList {
	public var symb : Uint8Array;
	public var d : Int;

	public function new(num:Int) {
		symb = new Uint8Array(num);
	}

	public function findOrAdd(c:Int):FindRes {
		//Main.print("findOrAdd "+c+" d="+d);
		for(i in 0...d)
			if (symb[i]==c) return Found;
		if (d < symb.length) {
			symb[d] = c; d++; return Added;
		}
		return NoRoom;
	}

	public function show() {
		//super.show();
		//Main.print("SymbList: d=" + d + " " + symb);
	}
}

class Cx1 extends SymbList {
	public function new(c:Int) {
		super(14);
		//kind = 1;
		d = 1;
		symb[0] = c;
	}
}

class Cx2 extends SymbList {
	public function new(c1 : Cx1, c:Int) {
		super(64);
		//kind = 2;
		for (i in 0...c1.d)
			symb[i] = c1.symb[i];
		symb[c1.d] = c;
		d = c1.d + 1;
	}
}

class Cx3 extends SymbList {
	public function new(c2 : Cx2, c:Int) {
		super(256);
		//kind = 3;
		for (i in 0...c2.d)
			symb[i] = c2.symb[i];
		symb[c2.d] = c;
		d = c2.d + 1;
	}
}

class SmallContext {
	public var	d : Int;
	var maxpos : Int; //maxpos is position of symbol with max freq value
	var S : Int; // size: 4 or 16
	public var symbols : Uint8Array;   //symbols met, sorted
	public var freqs : Uint16Array;
	static inline var f0 = 50;// STEP_CX5;
	static var totFr : Int;

	public function new(size : Int) {
		S = size;
		symbols = new Uint8Array(S);
		freqs = new Uint16Array(S);
		maxpos = 0;
	}

	function create(c1 : Cx1, c : Int):Void {
		d = c1.d;
		var ss = c1.symb.subarray(0, d);
		//untyped ss.sort();
		Sorter.insort(ss);
		for (i in 0...d) {
			symbols[i] = ss[i];
			if (symbols[i]==c) {
				freqs[i] = 2* SmallContext.f0; maxpos = i;
			} else
				freqs[i] = SmallContext.f0;
		}
	}

	function addSymb(pos:Int, c:Int/*, uint16_t &totFr*/):Bool {
		if (d == S) return false;
		var i = d - 1;
		while(i >= pos) {
			symbols[i + 1] = symbols[i]; freqs[i + 1] = freqs[i];
			i--;
		}
		symbols[pos] = c; freqs[pos] = f0; d++;
		if (maxpos >= pos) maxpos++; //most probable symbol shifted too
		totFr += f0;
		if (totFr + f0 > Rans.PROB_SCALE) rescale(/*totFr*/);
		return true;
	}

	function rescale() { //sets SmallContext.totFr
		var s = 256 - d;
		for(i in 0...d) {
			freqs[i] -= freqs[i] >> 1;
			s += freqs[i];
		}
		totFr = s;
	}

	function decodeSC(someFreq:Int, rcv : DecReceiver, totFr0:Int):Bool {
		totFr = totFr0;
		var shift = 0, tot = totFr0;
		while (tot <= Rans.PROB_SCALE/2) {
			tot <<= 1; shift++;
		}
		someFreq >>= shift;
		var bonus = (Rans.PROB_SCALE - tot) >> shift; // unused code space, let's give it to most probable symbol
		var maxFreq = freqs[maxpos];
		freqs[maxpos] += bonus; // temporary change
		var cumFr = 0, cfr = 0, lastSymb = 0, pos = 0;
		while(pos < d) {
			var s = symbols[pos];
			var startFr = cumFr + s - lastSymb;
			if (someFreq < startFr) { //c < s
				rcv.c = someFreq - cumFr + lastSymb;
				cumFr = someFreq;
				rcv.cumFreq = cumFr << shift;	rcv.freq = 1 << shift;
				freqs[maxpos] = maxFreq;
				return addSymb(pos, rcv.c/*, totFr*/);
			}
			var fr = freqs[pos];
			if (startFr + fr > someFreq) { //s=c
				rcv.c = s;
				cumFr += rcv.c - lastSymb;
				rcv.cumFreq = cumFr << shift;	rcv.freq = fr << shift;
				freqs[maxpos] = maxFreq;
				freqs[pos] += f0; totFr += f0;
				if (pos != maxpos && freqs[pos] > freqs[maxpos])
					maxpos = pos;
				if (totFr + f0 > Rans.PROB_SCALE) rescale(/*totFr*/);
				return true;
			}
			// c > s, continue
			cumFr += s - lastSymb + fr;
			lastSymb = s + 1;
			pos++;
		}//while pos
		freqs[maxpos] = maxFreq;
		if (pos==d) { // still not found
			rcv.c = lastSymb + someFreq - cumFr;
			rcv.cumFreq = someFreq << shift;	rcv.freq = 1 << shift;
			return addSymb(pos, rcv.c/*, totFr*/);
		}
		trace("unreachable in decodeSC");
		return true;
	}
}

class Cx4 extends SmallContext {
	public function new(c1 : Cx1, c : Int) {
		super(4);
		//kind = 4;
		create(c1, c);
	}

	public function decode(someFreq:Int, rcv : DecReceiver):Bool {
		var totFr = freqs[0] + freqs[1] + freqs[2] + freqs[3] + 256 - d;
		return decodeSC(someFreq, rcv, totFr);
	}

	public function upgrade(c:Int) : CxU {
		return Kind5( Cx5.fromCx4(this, c) );
	}
}

class Cx5 extends SmallContext {
	var cntsum : Int;

	public function new() {
		super(16);
		//kind = 5;
	}

	public static function fromCx1(c1 : Cx1, c : Int):Cx5 {
		var cx = new Cx5();
		cx.create(c1, c);
		cx.calcSum();
		return cx;
	}

	public static function fromCx4(c4 : Cx4, c : Int):Cx5 {
		var cx = new Cx5();
		cx.createFrom4(c4, c);
		return cx;
	}

	function createFrom4(c4 : Cx4, c : Int) {
		var i = 0, dd = c4.d, j=0, totFr=0;
		while(i < dd && c4.symbols[i] < c) {
			symbols[i] = c4.symbols[i];
			totFr += freqs[i] = c4.freqs[i];
			i++;
		}
		var j = i;
		symbols[j] = c;
		totFr += freqs[j] = SmallContext.f0;
		j++;
		while(i < dd) {
			symbols[j] = c4.symbols[i];
			totFr += freqs[j] = c4.freqs[i];
			i++; j++;
		}
		d = dd + 1;
		if (totFr > Rans.PROB_SCALE) {
			rescale(/*cntsum*/);
			//cntsum = SmallContext.totFr;
		}
		calcSum();
	}

	function calcSum() {
		var totFr = 256 - d;
		for(i in 0...d) totFr += freqs[i];
		cntsum = totFr;
	}

	public function decode(someFreq:Int, rcv : DecReceiver):Bool {
		var res = decodeSC(someFreq, rcv, cntsum);
		cntsum = SmallContext.totFr;
		return res;
	}

	public function upgrade(c:Int):CxU
	{
		var cx = new Cx6();
		cx.createFrom5(this, c);
		return Kind6(cx);
	}
}

class Cx6  {
	public var symbols : Uint8Array;
	public var freqs : Uint16Array;
	public var cnts : Uint16Array;
	var d : Int;
	public var fshift : Int;

	static var _cnts : Uint16Array = new Uint16Array(256);
	static var _freqs : Uint16Array = new Uint16Array(512);

	/*public function new(N:Int) {
		freqs = new Uint16Array(N * 2);
		cnts = new Uint16Array(N);
	}*/
	static inline var Step = 25;
	static inline var f0 = 64;

	public function new() { /*kind = 6;*/ }

	inline function setFreq(i:Int, fr:Int, cf:Int) {
		freqs[i * 2] = fr; freqs[i * 2 + 1] = cf;
	}

	/*inline function getFreq(i:Int, f:Freq) {
		f.freq = freqs[i * 2];
		f.cumFreq = freqs[i * 2 + 1];
	}*/

	inline function readFreq(idx:Int) { return freqs[idx * 2]; }
	inline function readCumFreq(idx:Int) { return freqs[idx * 2 + 1]; }

	function init(S: Int) {
		symbols = new Uint8Array(S);
		freqs = new Uint16Array(S*2); // (fr, cumFr) pairs
		cnts = new Uint16Array(S + 1);
	}

	public function createFrom5(c5:Cx5, c:Int) { //c did not fit into c5
		init(32);
		var S = 32;
		var oldd = c5.d;

		var totFr = 256 - oldd;
		for(i in 0...oldd) totFr += c5.freqs[i];

		var shift = 0, tot = totFr;
		while (tot <= Rans.PROB_SCALE/2) {
			tot <<= 1; shift++;
		}
		var cumFr = 0, cfr = 0, lastSymb = 0;

		for(pos in 0...oldd) {
			var s = c5.symbols[pos];
			var startFr = cumFr + s - lastSymb;
			cumFr += s - lastSymb;
			cfr = c5.freqs[pos];
			var fr = cfr << shift;
			setFreq(pos, fr, cumFr << shift);
			cnts[pos] = fr - (fr >> 1);
			symbols[pos] = s;
			cumFr += cfr;
			lastSymb = s + 1;
		}

		fshift = shift;
		// find interval for c and add it too
		//auto fr = unmetSymbolInterval(c);
		var fr_freq = 1 << fshift;
		var fr_cumFreq = 0; // for c == 0
		if (c > 0) {
			var lowerSym = -1;
			//Freq lfr = {0,0};
			var lfreq = 0, lcumFreq = 0;
			for(i in 0...oldd) {
				var s = symbols[i];
				if (s > lowerSym && s < c) {
					lowerSym = s; lfreq = readFreq(i); lcumFreq = readCumFreq(i);
				}
			}
			if (lfreq > 0) {// found some lower neighbor
				fr_cumFreq = lcumFreq + lfreq + ((c - lowerSym - 1) << fshift);
			} else  // c > 0 but lower than all others
				fr_cumFreq = c << fshift;
		}
		setFreq(oldd, fr_freq, fr_cumFreq);
		cnts[oldd] = fr_freq - (fr_freq >> 1);
		symbols[oldd] = c;
		d = oldd + 1;

		//incrCnt(p);
		var step = Step << fshift;
		cnts[oldd] += step;
		cnts[S] += step;
		if (cnts[S] + step > Rans.PROB_SCALE) rescaleDec();

		calcSum();
		//sort by freqs...
		for(i in 0 ... d-1)
			for (j in i + 1 ... d) {
				var fj = readFreq(j), fi = readFreq(i);
				if (fj > fi) {
					//std::swap(freqs[i], freqs[j]);
					var cfi = readCumFreq(i), cfj = readCumFreq(j);
					setFreq(i, fj, cfj);
					setFreq(j, fi, cfi);
					//std::swap(cnts[i], cnts[j]);
					var tc = cnts[i]; cnts[i] = cnts[j]; cnts[j] = tc;
					//std::swap(symbols[i], symbols[j]);
					var ts = symbols[i]; symbols[i] = symbols[j]; symbols[j] = ts;
				}
			}
	}

	public function createFrom2(cx:Cx2, c:Int) {
		var S0 = cx.d <= 32 ? 32 : 64;
		init(S0);
		//inline var f0 = 64;
		var oldd = cx.d;

		var totFr = 256 - oldd;
		totFr += oldd * f0 + f0; // +f0 for the c which is met 2nd time

		var shift = 0, tot = totFr;
		while (tot <= Rans.PROB_SCALE/2) {
			tot <<= 1; shift++;
		}
		var cumFr = 0, cfr = 0, lastSymb = 0;
		var ss = cx.symb.subarray(0, oldd);
		//untyped ss.sort();
		Sorter.insort(ss);
		var newSymbPos = 0;
		for(pos in 0...oldd) {
			var s = cx.symb[pos];
			var startFr = cumFr + s - lastSymb;
			cumFr += s - lastSymb;
			if (s == c) {
				newSymbPos = pos;
				cfr = f0 * 2;
			} else
				cfr = f0;
			var fr = cfr << shift;
			setFreq(pos, fr, cumFr << shift);
			symbols[pos] = s;
			cnts[pos] =  fr - (fr >> 1);
			cumFr += cfr;
			lastSymb = s + 1;
		}
		d = oldd;
		fshift = shift;
		calcSum();
		//sortByFreqs
		if (newSymbPos > 0) { // put that symbol on 0th position
			var fr0 = readFreq(0), cf0 = readCumFreq(0), frc = readFreq(newSymbPos), cfc = readCumFreq(newSymbPos);
			setFreq(0, frc, cfc);
			setFreq(newSymbPos, fr0, cf0);
			var sym0 = symbols[0], cnt0 = cnts[0], cntc = cnts[newSymbPos];
			cnts[0] = cntc;
			cnts[newSymbPos] = cnt0;
			symbols[0] = c;
			symbols[newSymbPos] = sym0;
		}
	}

	public function show() {
		var S = symbols.length;
		Logging.MLog("Cx6 " + " d=" + d + " S=" + S + " fshift=" + fshift);
		for(i in 0...S)
			if (cnts[i] > 0) {
				var c = symbols[i];
				var p0 = c & (S-1);
				var dist = i - p0;
				if (dist < 0) dist += S;
				Logging.MLog("tab["+i+"]={ c="+c+" dist="+dist+" p0="+p0+" fr="+readFreq(i)+","+readCumFreq(i)+" cnt="+cnts[i]+"} ");
			}
		Logging.MLog("cntsum="+cnts[S]);
	}

	function calcSum() {
		var shft = fshift > 0 ? fshift-1 : 0;
		var sum = (256 - d) << shft;
		var S = symbols.length;
		for(i in 0...S)
			sum += cnts[i];
		cnts[S] = sum;
	}

	function rescaleDec() {
		var sh = fshift > 0 ? fshift-1 : 0;
		var c0 = 1 << sh;
		for(i in 0...256)
			_cnts[i] = c0;
		for(i in 0...d)
			_cnts[ symbols[i] ] = cnts[i];
		var cumFr = 0;
		for(i in 0...256) {
			_freqs[i*2] = _cnts[i];
			_freqs[i*2+1] = cumFr;
			cumFr += _cnts[i];
		}
		if (fshift > 0) fshift--;
		var shft = fshift > 0 ? fshift-1 : 0;
		var cntsum = (256 - d) << shft;

		for(i in 0...d) {
			cnts[i] -= cnts[i] >> 1;
			cntsum += cnts[i];
			var idx = symbols[i];
			setFreq(i, _freqs[idx * 2], _freqs[idx * 2 + 1]); //freqs[i] = _freqs[ symbols[i] ];
		}
		cnts[symbols.length] = cntsum;
	}

	public function decode(someFreq:Int, rcv:DecReceiver):Bool
	{
		var lfreq = 0, lcumFreq =  0, lowerSym = 0;
		for(i in 0...d) {
			var cf = readCumFreq(i);// freqs[i].cumFreq;
			if (cf <= someFreq) {
				var fr = readFreq(i);
				if (cf + fr > someFreq) {//found
					rcv.c = symbols[i]; rcv.freq = fr; rcv.cumFreq = cf; //interval = freqs[i];
					incrCntDec(i); return true;
				}
				if (cf >= lcumFreq) {
					lfreq = fr; lcumFreq = cf; lowerSym = symbols[i];
				}
			}
		}
		//symbol not in table
		//Freq fr;
		var fr_freq = 1 << fshift, fr_cumFreq = 0, c = 0;
		if (lfreq > 0) {//lfr is closest lower one, c = lowerSym + ..
			var cumFr = lcumFreq + lfreq;
			var x = (someFreq - cumFr) >> fshift; //x = c - lowerSym - 1
			c = x + lowerSym + 1;
			fr_cumFreq = lcumFreq + lfreq + (x << fshift);
			/*if (c > 255) {
				trace("Cx6.decode(" + someFreq + ") lfreq=" + lfreq + " lcumFreq=" + lcumFreq + " fshift=" + fshift
				 + " x=" + x + " lowerSym="+lowerSym +" fr_cumFreq="+fr_cumFreq + " c="+c);
				js.Lib.debug();
			}*/
		} else { // c < all known
			c = someFreq >> fshift;
			fr_cumFreq = c << fshift;
			//if (c > 255) js.Lib.debug();
		}
		//interval = fr;
		rcv.freq = fr_freq; rcv.cumFreq = fr_cumFreq; rcv.c = c;
		var p = addDec(c, fr_freq, fr_cumFreq);
		if (p < 0) {
			if (symbols.length==64) return false; // todo: get rid of two phases, always be 40
			growDec();
			p = addDec(c, fr_freq, fr_cumFreq);
		}
		incrCntDec(p);
		return true;
	}//decode

	function addDec(c:Int, freq:Int, cumFreq:Int):Int { // => pos or -1 if full
		if (d >= /*MaxD6*/40 || d >= symbols.length) return -1;
		//assert(fr.freq > 0);
		var pos = d;
		symbols[pos] = c;
		setFreq(pos, freq, cumFreq); //freqs[pos] = fr;
		cnts[pos] = freq - (freq >> 1);
		d++;
		return pos;
	}

	function growDec() {
		var S = symbols.length * 2;
		var sym = new Uint8Array(S);
		var cs = new Uint16Array(S + 1);
		var fs = new Uint16Array(S * 2);
		for (i in 0...d) {
			sym[i] = symbols[i];
			cs[i] = cnts[i];
			fs[i * 2] = freqs[i * 2];
			fs[i * 2 + 1] = freqs[i * 2 + 1];
		}
		cs[S] = cnts[symbols.length]; //cntsum
		symbols = sym;
		cnts = cs;
		freqs = fs;
	}

	function incrCntDec(pos:Int) {
		var step = Step << fshift;
		var S = symbols.length;
		cnts[pos] += step;
		cnts[S] += step;
		if (pos > 0 && cnts[pos] > cnts[pos-1]) {
			//std::swap(cnts[pos], cnts[pos-1]);
			var tc = cnts[pos]; cnts[pos] = cnts[pos - 1]; cnts[pos - 1] = tc;
			//std::swap(freqs[pos], freqs[pos-1]);
			var fp = readFreq(pos), cfp = readCumFreq(pos);
			setFreq(pos, readFreq(pos - 1), readCumFreq(pos - 1));
			setFreq(pos - 1, fp, cfp);
			//std::swap(symbols[pos], symbols[pos-1]);
			var ts = symbols[pos]; symbols[pos] = symbols[pos - 1]; symbols[pos - 1] = ts;
		}
		if (cnts[S] + step > Rans.PROB_SCALE) rescaleDec();
	}

	public function upgrade(c:Int):CxU
	{
		var cx = new Cx7();
		cx.createFrom6(this, c);
		return Kind7(cx);
	}
}// Cx6

class Cx7 extends FixedSizeRansCtx {
	public function new() {
		super(256); //kind = 7;
	}

	public function createFrom3(c3:Cx3, c:Int) {
		for(i in 0...256) {
			freqs[i*2] = 1; //freq=1
			cnts[i] = 1;
		}
		var d = c3.d;
		var f0 : Int = Std.int( (Rans.PROB_SCALE - (256-d)) / (d+1) );
		var c0 = f0 - (f0 >> 1);
		for(i in 0...d) {
			var s = c3.symb[i];
			freqs[s*2] = f0;
			cnts[s] = c0;
		}
		freqs[c*2] += f0;
		cnts[c] += FixedSizeRansCtx.step;
		cntsum = 0; var cf = 0;
		for(i in 0...256) {
			cntsum += cnts[i];
			freqs[i*2+1] = cf;
			var fr = freqs[i*2];
			//for(int j=cf; j<cf + fr; j++)
			//	if ((j & (D-1)) == 0) decTable[j >> Dshift] = i;
			var k0 = (cf + FixedSizeRansCtx.D-1) >> FixedSizeRansCtx.Dshift;//first z >= cf, such that z = D*k
			var k1 = ((cf + fr - 1) >> FixedSizeRansCtx.Dshift) + 1;
			for(k in k0...k1)
				decTable[k] = i;
			cf += fr;
		}
	}

	public function createFrom6(c6:Cx6, c:Int) {
		var S = c6.symbols.length;
		cntsum = c6.cnts[S];

		for(i in 0...S) if (c6.cnts[i] > 0) {
			var x = c6.symbols[i];
			setFreq(x,  c6.freqs[i*2], c6.freqs[i*2+1]);
			cnts[x] = c6.cnts[i];
		}
		var funmet = 1 << c6.fshift;
		var cntUnmet = funmet - (funmet >> 1);
		var cumFr = 0;
		for(i in 0...256) {
			var fr = 0;
			if (freqs[i*2]>0) {
				//assert(cumFr == cxdata->freqs[i].cumFreq);
				fr = freqs[i*2];
			} else {
				setFreq(i, funmet, cumFr);
				cnts[i] = cntUnmet;
				fr = funmet;
			}
			//for(int j=cumFr; j<cumFr + fr; j++)
			//	if ((j & (D-1)) == 0) decTable[j >> Dshift] = i;
			var k0 = (cumFr + FixedSizeRansCtx.D-1) >> FixedSizeRansCtx.Dshift;//first z >= cf, such that z = D*k
			var k1 = ((cumFr + fr - 1) >> FixedSizeRansCtx.Dshift) + 1;
			for(k in k0...k1)
				decTable[k] = i;
			cumFr += fr;
		}
	}
}

enum CxU {
	KindNone;
	Kind1(c1:Cx1);
	Kind2(c2:Cx2);
	Kind3(c3:Cx3);
	Kind4(c4:Cx4);
	Kind5(c5:Cx5);
	Kind6(c6:Cx6);
	Kind7(c7:Cx7);
}

class Context {
	var u : CxU;
	public static var rcv : DecReceiver;

	public function new() { u = KindNone; rcv = { c:0, freq:0, cumFreq:0 }; }

	public function show() { /*if (u != null) u.show(); else trace("Context.show: kind = 0");*/ }

	public function renew() { u = KindNone; }

    public function decode(someFreq:Int):Bool {  // updates stats, if true sets c and interval (freq, cumFreq)
		//each call site has different type of x
		//monomorphic call - good for JS engine!
		switch(u) { //ideally should be ordered in decreasing probability order
			case Kind6(x) : if (!x.decode(someFreq, rcv)) u = x.upgrade(rcv.c);
			case Kind7(x) : x.decode(someFreq, rcv); //aways true
			case Kind4(x) : if (!x.decode(someFreq, rcv)) u = x.upgrade(rcv.c);
			case Kind5(x) : if (!x.decode(someFreq, rcv)) u = x.upgrade(rcv.c);
			case Kind1(_) | Kind2(_) | Kind3(_) | KindNone: return false;
		}
		/*if (u == null || u.kind < 4) return false;
		if (!u.decode(someFreq, this)) {
			u = u.upgrade(c);
		}*/
		return true;
	}

	public function update(c:Int):Void {
		switch(u) {
			case KindNone: u = Kind1( new Cx1(c) );
			case Kind1(x): updateC1(c, x);
			case Kind2(x): updateC2(c, x);
			case Kind3(x): updateC3(c, x);
			case Kind4(_) | Kind5(_) | Kind6(_) | Kind7(_): trace("unexpected kind in Context.update");
		}

		/*if (u == null) { u = new Cx1(c); }
		else {
			switch(u.kind) {
				case 1: updateC1(c);
				case 2: updateC2(c);
				case 3: updateC3(c);
			}
		}*/
	}

	function updateC1(c:Int, c1:Cx1):Void {
		switch(c1.findOrAdd(c)) {
			case Found:
				if (c1.d <= 4) u = Kind4( new Cx4(c1, c) );
				else u = Kind5( Cx5.fromCx1(c1, c) );
			case Added:
			case NoRoom: u = Kind2( new Cx2(c1, c) );
		}
	}

	function updateC2(c:Int, c2:Cx2):Void {
		switch(c2.findOrAdd(c)) {
			case Found:
				var cx = new Cx6();
				cx.createFrom2(c2, c);
				u = Kind6( cx );
			case Added:
			case NoRoom: u = Kind3( new Cx3(c2, c) );
		}
	}

	function updateC3(c:Int, c3:Cx3):Void {
		switch(c3.findOrAdd(c)) {
			case Found:	//u.c7 = upgradeTo7<Cx3>(u.c3, c, decoding); break;
				var cx = new Cx7(); cx.createFrom3(c3, c); u = Kind7(cx);
			case Added:
			case NoRoom: trace("c3.findOrAdd returned NoRoom"); //must not happen
		}
	}
}//Context

class Sorter {
	public static function insort(a:Uint8Array) { //insertion sort for small arrays
		for (i in 1...a.length) {
			var j = i;
			while (j > 0 && a[j - 1] > a[j]) {
				var t = a[j]; a[j] = a[j - 1]; a[j - 1] = t;
				j--;
			}
		}
	}
}