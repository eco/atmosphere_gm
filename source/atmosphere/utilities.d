module atmosphere.utilities;

import std.traits;
import core.stdc.tgmath;
import core.stdc.string : memmove;

package:

public import std.numeric : findRoot;
public import std.algorithm : minPos;
public import std.math : isFinite;


import cblas;
import simple_matrix;


/*
Computes accurate sum of binary logarithms of input range $(D r).
Will be avalible in std.numeric with with DMD 2.068.
 */
T sumOfLog2s(T)(T[] r) 
{
	import std.math : frexp; 
	import std.traits : Unqual;

    long exp = 0;
    Unqual!(typeof(return)) x = 1; 
    foreach (e; r)
    {
        if (e < 0)
            return typeof(return).nan;
        int lexp = void;
        x *= frexp(e, lexp);
        exp += lexp;
        if (x < 0.5) 
        {
            x *= 2;
            exp--;
        }
    }
    return exp + log2(x); 
}


auto sum(Range)(Range range) if(!isArray!Range)
{
	Unqual!(ForeachType!Range) s = 0;
	foreach(elem; range)
		s += elem;
	return s;
}

F sum(F)(in F[] a)
{
	F ret0 = 0;
	F ret1 = 0;
	F ret2 = 0;
	F ret3 = 0;

	const L1 = a.length & -0x10;
	const L2 = a.length & -0x4;

	size_t i;

	for(; i < L1; i += 0x10)
	{
	    ret0 += a[i+0x0];
	    ret1 += a[i+0x1];
	    ret2 += a[i+0x2];
	    ret3 += a[i+0x3];
	    ret0 += a[i+0x4];
	    ret1 += a[i+0x5];
	    ret2 += a[i+0x6];
	    ret3 += a[i+0x7];
	    ret0 += a[i+0x8];
	    ret1 += a[i+0x9];
	    ret2 += a[i+0xA];
	    ret3 += a[i+0xB];
	    ret0 += a[i+0xC];
	    ret1 += a[i+0xD];
	    ret2 += a[i+0xE];
	    ret3 += a[i+0xF];
	}

	for(; i < L2; i += 0x4)
	{
	    ret0 += a[i+0x0];
	    ret1 += a[i+0x1];
	    ret2 += a[i+0x2];
	    ret3 += a[i+0x3];
	}

	for(; i < a.length; i += 0x1)
	{
	    ret0 += a[i+0x0];
	}

	return (ret0+ret1)+(ret2+ret3);
}

unittest {
	import std.range : iota, array;
	foreach(i; 0.0..30.0)
		assert(iota(i).sum == iota(i).array.sum);
}


auto avg(Range)(Range range)
{
	return range.sum / range.length;
}


void normalize(F)(F[] range)
{
	immutable s = range.sum;
	assert(s.isFinite);
	assert(s > 0);
	foreach(ref elem; range)
		elem /= s;
}


void gemv(M, F)(in M m, in F[] a, F[] b)
in {
	assert (m.width == a.length);
	assert (m.height == b.length);
}
body {

	static if(is(M : Matrix!(T), T))
	{
		assert(m.ptr);
		assert(m.shift >= m.width);
		cblas.gemv(
			Order.RowMajor,
			Transpose.NoTrans,
			cast(blasint)b.length,
		 	cast(blasint)a.length,
			1.0,
			m.ptr,
			cast(blasint)m.shift,
			a.ptr,
			1,
			0.0,
			b.ptr,
			1);
	}
	else
	static if(is(M : TransposedMatrix!T, T))
	{
		assert(m.matrix.ptr);
		assert(m.matrix.shift >= m.matrix.width);
		cblas.gemv(
			Order.RowMajor,
			Transpose.Trans,
			cast(blasint)a.length,
		 	cast(blasint)b.length,
			1.0,
			m.matrix.ptr,
			cast(blasint)m.matrix.shift,
			a.ptr,
			1,
			0.0,
			b.ptr,
			1);
	}
	else
	{
		import std.string : format;
		static assert(0, format("gemv for %s not implimented", M.stringof));
	}
}

unittest
{
	const ar = [
	 1.000,  6.000,   2.000,
	 8.000,  3.000,   7.000,
	 3.000,  5.000,   2.000,
	53.000, 23.000, 123.000,
	];
	auto m = Matrix!(const double)(ar.ptr, 4, 3);
	const a = [
	42.000,
	35.000,
	12.000,
	];
	auto b = new double[4];
	gemv(m, a, b);
	assert(b == [ 
	 276.000,
	 525.000,
	 325.000,
	4507.000,
	]);

}


unittest
{
	const ar = [
  	1.000,   8.000,  3.000,  53.000,
  	6.000,   3.000,  5.000,  23.000,
  	2.000,   7.000,  2.000, 123.000,
	];
	auto m = Matrix!(const double)(ar.ptr, 3, 4);
	const a = [
	42.000,
	35.000,
	12.000,
	];
	auto b = new double[4];
	gemv(m.transposed, a, b);
	assert(b == [ 
	 276.000,
	 525.000,
	 325.000,
	4507.000,
	]);

}


auto dot(Range1, Range2)(Range1 r1, Range2 r2)
{
	return cblas.dot(cast(blasint)r1.length, r1.ptr, cast(blasint)r1.shift, r2.ptr, cast(blasint)r2.shift);
}

ptrdiff_t shift(F)(F[])
{
	return 1;
}

void scal(Range, T)(Range r, T alpha)
{
	cblas.scal(cast(blasint)r.length, alpha, r.ptr, cast(blasint)r.shift);
}


/**
Struct that represent flat matrix.
Useful for sliding windows.
*/
struct MatrixColumnsSlider(F)
{
	Matrix!F _matrix;
	Matrix!F matrix;

	this(size_t maxHeight, size_t maxWidth, size_t height)
	{
		_matrix = Matrix!F(maxHeight, maxWidth);
		_matrix.width = _matrix.shift;
		matrix.ptr = _matrix.ptr;
		matrix.shift = _matrix.shift;
		matrix.height = height;
	}

	void popFrontN(size_t n)
	in 
	{
		assert(n <= matrix.width, "n > matrix.width");
	}
	body 
	{
		if(n < matrix.width)
		{
			matrix.width -= n;
			matrix.ptr += n;
		}
		else
		{ 
			reset;
		}
	}

	void popFront()
	{
		popFrontN(1);
	}

	void reset()
	{
		matrix.ptr = _matrix.ptr;
		matrix.width = 0;
	}

	void putBackN(size_t n)
	in
	{
		assert(matrix.shift >= matrix.width+n);
	}
	body 
	{
		if(n > _matrix.ptrEnd-matrix.ptrEnd)
		{
			bringToFront();
		}
		matrix.width += n;
	}

	void putBack()
	{
		putBackN(1);
	}

	void bringToFront()
	{
		if(matrix.width)
		{
			memmove(_matrix.ptr, matrix.ptr, (matrix.shift*matrix.height)*F.sizeof);					
		}
		matrix.ptr = _matrix.ptr;
	}
}
