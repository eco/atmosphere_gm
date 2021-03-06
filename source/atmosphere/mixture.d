/**
Module contains classes that perform optimization of mixture weights over sliding window.
------
problem: p' = argmin f(p), p_i >= 0, Σ_i p_i = 1.

p - mixture weights,
f = u(Wp),
u(ω) - convex function,
W - matrix of features(n rows, k columns),
k - length of mixture weights,
n - length of sample, n may vary (sliding window).
------

The same for likelihood maximization:
------
problem: p' = argmax L(p), p_i >= 0, Σ_i p_i = 1.

L(ω) = u(Wp)
ω = Wp,
u(ω) = Σ_j log(ω_j)  (LogLikelihood)

p - mixture weights,
f_i - mixture components
W - matrix of posterior probabilities(n rows, k columns),
W[j, i] = f_i(x_j), 1 <= i <= k, 1 <= j <= n.

k - length of mixture weights (count of ),
n - length of sample, n may vary (sliding window).
------

Example:
-------
import atmosphere;

import std.math;

//probability density function
static struct PDF
{
	double alphau;
	double sqrtu;

	this(double alpha, double u)
	{
		alphau = alpha * u;
		sqrtu = sqrt(u);
	}

	///call operator overloading
	double opCall(double x) const
	{
		immutable y = (x - alphau) / sqrtu;
		//up to a constant!
		return exp(y * y / -2) / sqrtu;
	}
}

double[] mySample, myNewSample;
PDF[] pdfs;
//... initialize pdfs and mySample.

auto optimizer = new CoordinateLikelihoodMaximization!double(pdfs.length, mySample.length+1000);

bool delegate(double, double) tolerance = 
	(likelihoodPrev, likelihood) 
	=> likelihood - likelihoodPrev <= 1e-3;

optimizer.put(pdfs, mySample);
optimizer.optimize(tolerance);

double[] mixtureWeights = optimizer.weights.dup;

//remove first 50 elements in sample.
optimizer.popFrontN(50);

//... initialize myNewSample.
//check length <= 1050
assert(myNewSample.length <= 1050);

// add new sample
optimizer.put(pdfs, myNewSample);
optimizer.optimize(tolerance);

double[] mixtureWeights2 = optimizer.weights.dup;
-------
*/
module atmosphere.mixture;


import atmosphere.internal;
import atmosphere.utilities : sumOfLog2s;
import std.range;
import std.traits;
import std.numeric;
///**
//In most cases coordinate descent is much more faster then gradient descent.
//*/
//module atmosphere.stationary;

import atmosphere.internal;

/**
Params:
	T = floating point type
*/
abstract class MixtureOptimizer(T)
{
	package SlidingWindow!T _featuresT;
	package T[] _weights;
	package T[] _mixture;

	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		_featuresT = SlidingWindow!T(k, maxLength);
		_weights = new T[k];
		_weights[] = T(1)/k;
		_mixture = new T[maxLength];
	}

	/**
	Perform k (1) iterations of coordinate (gradient or EM) descent optimization algorithm.
	Params:
	findRootTolerance = Defines an early termination condition. 
			Receives the current upper and lower bounds on the root. 
			The delegate must return true when these bounds are acceptable.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	abstract void eval(scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null);

	/**
	update method is called when mixture changes occur.
	*/
	abstract void update();

final:

	/**
	Performs optimization.
	Params:
		objectiveFunction = accepts mixture.
		tolerance = Defines an early termination condition. 
			Receives the current and previous versions of $(D objectiveFunction(mixture)) and weights. 
			The delegate must return true when mixture and weights are acceptable. 
		findRootTolerance = Tolerance for inner optimization.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	void optimize(
			scope T delegate(in T[] mixture) objectiveFunction, 
			scope bool delegate (T objectiveFunctionValuePrev, T objectiveFunctionValue, in T[] weightsPrev, in T[] weights) tolerance,
			scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
		)
	{
		T objectiveFunctionValuePrev;
		T objectiveFunctionValue = objectiveFunction(mixture);
		T[] weightsPrev = new T[weights.length];
		do
		{
			objectiveFunctionValuePrev = objectiveFunctionValue;
			weightsPrev[] = weights[];
			eval(findRootTolerance);
			objectiveFunctionValue = objectiveFunction(mixture);
		}
		while(!tolerance(objectiveFunctionValuePrev, objectiveFunctionValue, weightsPrev, weights));
	}

	/**
	Performs optimization.
	Params:
		objectiveFunction = accepts mixture.
		tolerance = Defines an early termination condition. 
			Receives the current and previous versions of $(D objectiveFunction(mixture)). 
			The delegate must return true when mixture are acceptable. 
		findRootTolerance = Tolerance for inner optimization.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	void optimize
	(
		scope T delegate(in T[] mixture) objectiveFunction, 
		scope bool delegate (T objectiveFunctionValuePrev, T objectiveFunctionValue) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	)
	{
		T objectiveFunctionValuePrev;
		T objectiveFunctionValue = objectiveFunction(mixture);
		do
		{
			objectiveFunctionValuePrev = objectiveFunctionValue;
			eval(findRootTolerance);
			objectiveFunctionValue = objectiveFunction(mixture);
		}
		while(!tolerance(objectiveFunctionValuePrev, objectiveFunctionValue));
	}

	/**
	Performs optimization.
	Params:
		tolerance = Defines an early termination condition. 
			Receives the current and previous versions of weights. 
			The delegate must return true when mixture and weights are acceptable. 
		findRootTolerance = Tolerance for inner optimization.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	void optimize
	(
		scope bool delegate (in T[] weightsPrev, in T[] weights) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	)
	{
		T[] weightsPrev = new T[weights.length];
		do
		{
			weightsPrev[] = weights[];
			eval(findRootTolerance);
		}
		while(!tolerance(weightsPrev, weights));
	}

	/**
	Puts back new feature for each components.
	Params:
		features = One feature per component.
	Preconditions:
		---------
		features.length == weights.length
		length+1 <= maxLength
		---------
	*/
	void put(Range)(Range features)
	if(isInputRange!Range && hasLength!Range && isNumeric!(ElementType!Range))
	in
	{
		assert(_featuresT.matrix.length == featuresROR.length);
		assert(_featuresT.matrix.width < _featuresT.matrix.shift);
	}
	body
	{
		_featuresT.put(features);
		updateMixtureBack;
	}


	/**
	Puts back new features for each components.
	Params:
		featuresROR = Range of ranges of features per component.
	Preconditions:
		---------
		featuresROR[j].length == weights.length
		length+featuresROR.length <= maxLength
		---------
	*/
	void put(RangeOfRanges)(RangeOfRanges featuresROR)
	if(isInputRange!RangeOfRanges && hasLength!RangeOfRanges && 
		isInputRange!(ElementType!RangeOfRanges) && hasLength!(ElementType!RangeOfRanges) && 
		isNumeric!(ElementType!(ElementType!RangeOfRanges)))
	in
	{
		assert(_featuresT.matrix.length == featuresROR.front.length);
		assert(_featuresT.matrix.width + featuresROR.length <= _featuresT.matrix.shift);
	}
	body
	{
		const n = featuresROR.length;
		.put(_featuresT, featuresROR);
		updateMixtureBackN(n);
	}

	/**
	Returns:
		current length of features for each component
	*/
	size_t length() @property const
	{
		return _featuresT.matrix.width;
	}

	/**
	Returns:
		maximal allowed length of features
	*/
	size_t maxLength() @property const
	{
		return _featuresT.matrix.shift;
	}


	/**
	Reset length of features to zero.
	*/
	void reset()
	{
		_featuresT.reset;
	}

	/**
	Remove one front feature for each component.
	*/
	void popFront()
	in
	{
		assert(length);
	}
	body
	{
		_featuresT.popFront;
		_mixture[0.._featuresT.length] = _mixture[1.._featuresT.length+1];
	}

	/**
	Remove n front features for each component.
	Params:
		n = features will be removed
	*/
	void popFrontN(size_t n)
	in
	{
		assert(length >= n);
	}
	body
	{
		_featuresT.popFrontN(n);
		_mixture[0.._featuresT.length] = _mixture[n.._featuresT.length+n];
	}

	/**
	Returns:
		Range of range of features for each component. A matrix with k rows and n columns.
		This is internal representation, and can be discarded after any methods calls.
	*/
	Matrix!(const(T)) features() const
	{
		return cast(typeof(return))_featuresT.matrix;
	}

	/**
	Returns:
		Const slice of the internal mixture representation.
	Example:
	-------------
	double objectiveFunction(in double[])
	{
	
	}

	//save slice
	auto mixture = optimizer.mixture;

	auto value0 = objectiveFunction(mixture);
	optimizer.eval;
	auto value1 = objectiveFunction(mixture);


	//use $(D .dup) or copy to save current mixture

	//1: .dup
	auto mixtureSave1 = mixture.dup;

	//2: create array
	auto mixtureSave2 = new double[mixture.length];
	//2: copy
	mixtureSave2[] = mixture[];
	-------------
	*/
	const(T)[] mixture() @property const
	{
		return _mixture[0.._featuresT.length];
	}

	/**
	Returns:
		Const slice of the internal weights representation.
	Example:
	-------------
	//save slice
	auto weights = optimizer.weights;

	//use $(D .dup) or copy to save current weights

	//1: .dup
	auto weightsSave1 = weights.dup;

	//2: create array
	auto weightsSave2 = new double[weights.length];
	//2: copy
	weightsSave2[] = weights[];
	-------------
	*/
	const(T)[] weights() @property const
	{
		return _weights;
	}

	/**
	Set the mixture weights and calls $(MREF update).
	Params:
		_weights = new mixture weights
	*/
	void weights(in T[] _weights) @property
	{
		this._weights[] = _weights[];
		updateMixture;
	}

	package void updateMixture()
	{
		mix(cast(Matrix!(const T))_featuresT.matrix, _weights, _mixture[0.._featuresT.matrix.width]);
		update();
	}

	package void updateMixtureBack()
	{
		_mixture[_featuresT.matrix.width-1] = dotProduct(_weights, _featuresT.back);
		update();
	}

	package void updateMixtureBackN(size_t n)
	{
		mix(cast(Matrix!(const T))_featuresT[$-n..$].matrix, _weights, _mixture[0.._featuresT.matrix.width]);
		update();
	}

	package void updateMixturePopBack()
	{
		updateMixturePopBackN(1);
	}

	package void updateMixturePopBackN(size_t n)
	{
		_mixture[0.._featuresT.matrix.width-n] = _mixture[n.._featuresT.matrix.width];
		update();
	}
}


/**
Params:
	Gradient = Gradient of the objective function. $(D Gradient(a, b) should perform b = grad_f(a)).
	T = floating point type
*/
class GradientDescent(alias Gradient, T) : MixtureOptimizer!T
{
	private T[] pi;
	private T[] xi;
	private T[] gamma;
	private T[] c;

	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		super(k, maxLength);
		pi = new T[maxLength];
		xi = new T[maxLength];
		gamma = new T[maxLength];
		c = new T[k];
	}

	~this()
	{
		pi.destroy;
		xi.destroy;
		gamma.destroy;
		c.destroy;
	}

	final override void eval(scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null)
	{
		gradientDescentIteration!(Gradient, T)(cast(Matrix!(const T))_featuresT.matrix, _weights, mixture, pi[0.._featuresT.matrix.width], xi[0.._featuresT.matrix.width], gamma[0.._featuresT.matrix.width], c, findRootTolerance is null ? (a, b) => false : findRootTolerance);
		updateMixture;
	}

	override void update(){};
}


/**
Params:
	Gradient = Gradient of the objective function. $(D Gradient(a, b) should perform b = grad_f(a)).
	T = floating point type
*/
class CoordinateDescent(alias Gradient, T) : MixtureOptimizer!T
{
	private T[] pi;
	private T[] xi;
	private T[] gamma;

	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		super(k, maxLength);
		pi = new T[maxLength];
		xi = new T[maxLength];
		gamma = new T[maxLength];
	}

	~this()
	{
		pi.destroy;
		xi.destroy;
		gamma.destroy;
	}

	final override void eval(scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null)
	{
		coordinateDescentIteration!(Gradient, T)(cast(Matrix!(const T))_featuresT.matrix, _weights, mixture, pi[0.._featuresT.matrix.width], xi[0.._featuresT.matrix.width], gamma[0.._featuresT.matrix.width], findRootTolerance is null ? (a, b) => false : findRootTolerance);
		updateMixture;
	}

	override void update(){};
}


/**
Params:
	PartialDerivative = Partial derivative $(D y) of objective convex function $(D u): $(D du/dω_j = y(ω_j), 1 <= j <= n).
	T = floating point type
*/
class CoordinateDescentPartial(alias PartialDerivative, T) : MixtureOptimizer!T
{
	private T[] pi;

	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		super(k, maxLength);
		pi = new T[maxLength];
	}

	~this()
	{
		pi.destroy;
	}

	final override void eval(scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null)
	{
		coordinateDescentIterationPartial!(PartialDerivative, T)(cast(Matrix!(const T))_featuresT.matrix, _weights, _mixture[0.._featuresT.matrix.width], pi[0.._featuresT.matrix.width], findRootTolerance is null ? (a, b) => false : findRootTolerance);
		updateMixture;
	}

	override void update(){};
}


/**
Params:
	T = floating point type
*/
interface LikelihoodMaximization(T)
{
	/**
	See_Also:
		 $(STDREF traits, isCallable)
	*/
	void put(PDFRange, SampleRange)(PDFRange pdfs, SampleRange sample)
		if(isInputRange!PDFRange && hasLength!PDFRange && isCallable!(ElementType!PDFRange));

	/**
	Performs optimization.
	Params:
		tolerance = Defines an early termination condition. 
			Receives the current and previous versions of log2Likelihood and weights. 
			The delegate must return true when likelihood and weights are acceptable. 
		findRootTolerance = Tolerance for inner optimization.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	void optimize
	(
		scope bool delegate (T sumOfLog2sValuePrev, T sumOfLog2sValue, in T[] weightsPrev, in T[] weights) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	);

	/**
	Performs optimization.
	Params:
		tolerance = Defines an early termination condition. 
			Receives the current and previous versions of log2Likelihood. 
			The delegate must return true when likelihood are acceptable. 
		findRootTolerance = Tolerance for inner optimization.
	See_Also:
		$(STDREF numeric, findRoot)
	*/
	void optimize
	(
		scope bool delegate (T sumOfLog2sValuePrev, T sumOfLog2sValue) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	);
}

/**
Params:
	T = floating point type
*/
class CoordinateLikelihoodMaximization(T) : CoordinateDescentPartial!(a => -1/a, T), LikelihoodMaximization!T
{
	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		super(k, maxLength);
	}

	mixin LikelihoodMaximizationTemplate!T;
}

/**
Params:
	T = floating point type
*/
class GradientLikelihoodMaximization(T) : GradientDescent!((a, b) {foreach(i, ai; a) b[i]=-1/ai;}, T), LikelihoodMaximization!T
{
	/**
	Params:
		k = number of components
		maxLength = maximal length of features. In terms of likelihood maximization maxLength is maximal length of a sample.
	*/
	this(size_t k, size_t maxLength)
	{
		super(k, maxLength);
	}

	mixin LikelihoodMaximizationTemplate!T;
}


private mixin template LikelihoodMaximizationTemplate(T)
{
	void put(PDFRange, SampleRange)(PDFRange pdfs, SampleRange sample)
	if(isInputRange!PDFRange && hasLength!PDFRange && isCallable!(ElementType!PDFRange))
	in
	{
		assert(pdfs.length == _featuresT.matrix.height);
	}
	body
	{
		super.put(sample.map!(x => pdfs.map!(pdf => pdf(x))));
	}

	void optimize
	(
		scope bool delegate (T sumOfLog2sValuePrev, T sumOfLog2sValue, in T[] weightsPrev, in T[] weights) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	)
	{
		super.optimize((m => m.sumOfLog2s), tolerance, findRootTolerance);
	}

	void optimize
	(
		scope bool delegate (T sumOfLog2sValuePrev, T sumOfLog2sValue) tolerance,
		scope bool delegate(T a, T b) @nogc nothrow findRootTolerance = null,
	)
	{
		super.optimize((m => m.sumOfLog2s), tolerance, findRootTolerance);
	}
}

unittest {
	alias C0 = CoordinateDescent!((a, b){}, double);
	alias C1 = LikelihoodMaximization!(double);
	alias C10 = GradientLikelihoodMaximization!(double);
	alias C11 = CoordinateLikelihoodMaximization!(double);
	alias C2 = GradientDescent!((a, b){}, double);
}
