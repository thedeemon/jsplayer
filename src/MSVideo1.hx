package ;
import openfl.errors.Error;
import IVideoCodec;
import openfl.utils.ByteArray;
import js.html.Int32Array;
import js.html.Uint8Array;

class MSVideo1_16bit implements IVideoCodec
{
	//var prev_frame : Int; //pointer
	var X : Int;
	var Y : Int;
	var block_changes : Array<Bool>;
	var insignificant_blocks : Int;
	var insign_lines : Int;
	var size_of_just_skips : UInt;
	var prevFrame : Int32Array;
	var pal : Int32Array;

	public function new(width : Int, height : Int)
	{
		//trace("MSVC.new 16bit w=" + width + " h=" + height);
		//prev_frame = 0;
		X = width; Y = height;
		block_changes = new Array(/*height >> 2*/);
		block_changes[(height >> 2) - 1] = false;
		pal = new Int32Array(8);

		var nblocks = (X >> 2) * (Y >> 2);
		size_of_just_skips = Std.int(nblocks / 1023) * 2 + 10;
	}

	public function StopAndClean():Void
	{
	}

	public function Preinit(insignificant_lines : Int):Void
	{
		insignificant_blocks = (insignificant_lines + 3) >> 2;
		insign_lines = insignificant_lines;
	}

	/*public function BufferStartAddr():Int
	{
		return 8*4;
	}*/

	public function PreviousFrame():Int32Array
	{
		return prevFrame;
	}

	public function State():DecoderState
	{
		return zero_state;
	}

	public function RenewI():Void
	{
	}

	public function DecompressI(src:Uint8Array, dst:Int32Array):DecoderState //zero_state if done
	{
		//prev_frame = buffer_address;
		DecompressP(src, dst);
		return zero_state;
	}

	public function ContinueI():DecoderState
	{
		return zero_state;
	}

	inline function copy_block(di : Int, dst:Int32Array):Int
	{
		for (y in 0...4) {
			for (x in 0...4) {
				//Memory.setI32(di, Memory.getI32(di + frame_delta));
				dst[di+x] = prevFrame[di+x];
			}
			di += X;
		}
		return di;
	}

	function JustSkipBlocks(src:Uint8Array):Bool
	{
		var si = 0;
		var n = 0;
		var nblocks = (X >> 2) * (Y >> 2);
		var len = src.length;
		while (si < len) {
			var a = src[si];
			var b = src[si + 1];
			if ((b & 0xFC) == 0x84) {
				var skip = ((b - 0x84) << 8) + a;
				n += skip;
				if (n >= nblocks) return true;
			} else
				return false;
			si += 2;
		}
		return true;
	}

	public function DecompressP(src:Uint8Array, dst:Int32Array):PFrameResult //returns addr of decompressed data: buffer_address or prev_frame
	{
		//trace("MSVC.DecompressP sz=" + src.length);
		if (src.length == 0 || (src.length < size_of_just_skips && JustSkipBlocks(src)))
			return { data_pnt: prevFrame, significant_changes : false};
		var nbx = X >> 2;
		var skip = 0;
		var si = 0; // in bytes
		//src.position = 0;
		//var row_delta = X - 4;
		var block_delta = 4 - 4 * X;
		var changes = false;
		//var frame_delta = prev_frame - buffer_address;
		try {
		for (by in 0...Y>>2) {
			var di = by * X *4; // in pixels (ints)
			block_changes[by] = false;
			for (bx in 0...nbx) {
				if (skip != 0) {
					skip--;
					di = copy_block(di, dst);
				} else {
					var a = src[si]; //.readUnsignedByte();
					var b = src[si + 1];// .readUnsignedByte();
					si += 2;
					if ((b & 0xFC) == 0x84) {
						skip = ((b - 0x84) << 8) + a - 1;
						di = copy_block(di, dst);
					} else
					if (b < 0x80) {
						var flags = ((b << 8) + a) ^ 0xFFFF;
						var clr0 = src[si] + src[si + 1] * 256; //src.readUnsignedShort();

						pal[0] = fromRGB15( clr0 );
						pal[1] = srcRGB15(src, si + 2);
						si += 4;
						if (clr0 & 0x8000 != 0) {
							pal[2] = srcRGB15(src, si);
							pal[3] = srcRGB15(src, si + 2);
							pal[4] = srcRGB15(src, si + 4);
							pal[5] = srcRGB15(src, si + 6);
							pal[6] = srcRGB15(src, si + 8);
							pal[7] = srcRGB15(src, si + 10);
							si += 12;
							for (y in 0...4) {
								var ty = (y & 2) << 1;
								for (x in 0...4) {
									//Memory.setI32(di, Memory.getI32((ty + (x & 2) + (flags & 1)) << 2));
									dst[di+x] = pal[ty + (x & 2) + (flags & 1)];
									flags >>= 1;
								}
								di += X;
							}
						} else {
							for (y in 0...4) {
								for (x in 0...4) {
									//Memory.setI32(di, Memory.getI32((flags & 1)<<2));
									dst[di + x] = pal[flags & 1];
									flags >>= 1;
								}
								di += X;
							}
						}
						changes = true;
						block_changes[by] = true;
					} else {
						var clr = fromRGB15( (b << 8) + a );
						for (y in 0...4) {
							for (x in 0...4) {
								dst[di + x] = clr;	//Memory.setI32(di, clr);
							}
							di += X;
						}
						changes = true;
						block_changes[by] = true;
					}
				}
				di += block_delta;
			} //for bx
		} // for by
		} catch (e:Error) { /*trace("msvc err " + e); */}
		var signif = false;
		if (changes) {
			for (i in insignificant_blocks...Y>>2)
				if (block_changes[i]) {
					signif = true;
					break;
				}
		}
		if (signif && prevFrame != null) {
			signif = false;
			for (i in insign_lines * X...Y * X) {
				var di = i;
				if (dst[di] != prevFrame[di]) {
					signif = true;
					break;
				}
			}
		}
		//prev_frame = changes ? buffer_address : prev_frame;
		if (changes)
			prevFrame = dst;
		return {data_pnt : prevFrame, significant_changes : signif};
	}

	inline private function fromRGB15(c : Int):Int
	{
		return ((c & 0x1F) << 3) + ((c & 0x3E0) << 6) + ((c & 0x7C00) << 9);
	}

	inline private function srcRGB15(src : Uint8Array, si : Int):Int {
		var c = src[si] + src[si + 1] * 256;
		return ((c & 0x1F) << 3) + ((c & 0x3E0) << 6) + ((c & 0x7C00) << 9);
	}

	public function NeedsIndex():Bool
	{
		return true;
	}

	public function IsKeyFrame(src : Uint8Array):Bool
	{
		//trace("MSVC.DecompressP sz=" + src.length);
		if (src.length == 0) return false;
		var nbx = X >> 2;
		var skip = 0;
		var si = 0;
		var key = true;

		for (by in 0...Y>>2) {
			for (bx in 0...nbx) {
				if (skip != 0) {
					skip--;
				} else {
					var a = src[si];// .readUnsignedByte();
					var b = src[si + 1];// .readUnsignedByte();
					si += 2;
					if ((b & 0xFC) == 0x84) {
						skip = ((b - 0x84) << 8) + a - 1;
						key = false;
						return false; //why wasn't it here before?
					} else
					if (b < 0x80) {
						var clr0 = src[si] + src[si + 1] * 256;  //.readUnsignedShort();
						if (clr0 & 0x8000 != 0)
							si += 16;
						else
							si += 4;
					}
				}
			} //for bx
		} // for by
		return key;
	}
}//MSVideo1_16bit

class MSVideo1_8bit extends MSVideo1_16bit
{
	var pal8 : ByteArray;
	var p2 : Int32Array;

	public function new(width : Int, height : Int, palette : ByteArray)
	{
		//trace("MSVC.new 8bit");
		super(width, height);
		pal8 = palette;
		pal = new Int32Array(256);
		p2 = new Int32Array(8);
	}

	/*override public function BufferStartAddr():Int
	{
		return 8*4 + 256*4;
	}*/

	override public function Preinit(insignificant_lines : Int):Void
	{
		//pal.endian = Endian.LITTLE_ENDIAN;
		//pal.position = 0;
		var i = 0;
		while (i < 256 && pal8.bytesAvailable >= 4) {
			pal[i] = pal8.readUnsignedInt();
			i++;
		}
		insignificant_blocks = (insignificant_lines+3) >> 2;
	}

	override public function DecompressP(src:Uint8Array, dst:Int32Array):PFrameResult //returns addr of decompressed data: buffer_address or prev_frame
	{
		var nbx = X >> 2;
		var skip = 0;
		var si = 0;
		//var row_delta = (X - 4) * 4;
		var block_delta = 4 - 4 * X;
		var changes = false;
		//var frame_delta = prev_frame - buffer_address;
		try {
		for (by in 0...Y>>2) {
			var di = by * X * 4;
			block_changes[by] = false;
			for (bx in 0...nbx) {
				if (skip != 0) {
					skip--;
					di = copy_block(di, dst);
				} else {
					var a = src[si];// .readUnsignedByte();
					var b = src[si + 1];// .readUnsignedByte();
					if (a + b == 0) throw 0;
					si += 2;
					if ((b & 0xFC) == 0x84) {
						skip = ((b - 0x84) << 8) + a - 1;
						di = copy_block(di, dst);
					} else
					if (b < 0x80) {
						var flags = (b << 8) + a;

						p2[1] = pal[src[si]];
						p2[0] = pal[ src[si + 1] ];
						si += 2;
						for (y in 0...4) {
							for (x in 0...4) {
								//Memory.setI32(di, Memory.getI32(((flags & 1))<<2));
								dst[di + x] = p2[flags & 1];
								flags >>= 1;
							}
							di += X;
						}
						changes = true;
						block_changes[by] = true;
					} else
					if (b >= 0x90) {
						var flags = ((b << 8) + a) ^ 0xFFFF;
						for(i in 0...8)
							//Memory.setI32(i*4, from_pal( src.readUnsignedByte() ));
							p2[i] = pal[ src[si + i] ];
						si += 8;
						for (y in 0...4) {
							var ty = (y & 2) << 1;
							for (x in 0...4) {
								//Memory.setI32(di, Memory.getI32((ty + (x & 2) + (flags & 1))<<2));
								dst[di+x] = p2[ ty + (x & 2) + (flags & 1) ];
								flags >>= 1;
							}
							di += X;
						}
						changes = true;
						block_changes[by] = true;
					} else {
						var clr = pal[a];
						for (y in 0...4) {
							for (x in 0...4) {
								//Memory.setI32(di, clr);
								dst[di + x] = clr;
							}
							di += X;
						}
						changes = true;
						block_changes[by] = true;
					}
				}
				di += block_delta;
			}//for bx
		} //for by
		} catch (e : Int) { trace("exception!");  } //just exit the loop
		catch (e:Error) { /*trace("msvc err " + e);*/ }

		var signif = false;
		if (changes) {
		for (i in insignificant_blocks...Y>>2)
			if (block_changes[i]) {
				signif = true;
				break;
			}
		}
		if (signif && prevFrame!=null) {
			signif = false;
			for (i in insign_lines * X...Y * X) {
				if (dst[i] != prevFrame[i]) { //prevFrame is null the first time
					signif = true;
					break;
				}
			}
		}

		//prev_frame = changes ? buffer_address : prev_frame;
		if (changes) prevFrame = dst;
		return { data_pnt : prevFrame, significant_changes : signif };
	}

	override public function IsKeyFrame(src:Uint8Array):Bool
	{
		if (src.length == 0) return false;
		var nbx = X >> 2;
		var skip = 0;
		var si = 0;
		var key = true;
		try {
		for (by in 0...Y>>2) {
			for (bx in 0...nbx) {
				if (skip != 0) {
					skip--;
				} else {
					var a = src[si];// .readUnsignedByte();
					var b = src[si + 1]; //.readUnsignedByte();
					if (a + b == 0) throw 0;
					si += 2;
					if ((b & 0xFC) == 0x84) {
						skip = ((b - 0x84) << 8) + a - 1;
						key = false;
					} else
					if (b < 0x80) {
						si += 2;
					} else
					if (b >= 0x90) {
						si += 8;
					}
				}
			}//for bx
		} //for by
		} catch (e : Int) { trace("exception!");  } //just exit the loop
		return key;
	}

}