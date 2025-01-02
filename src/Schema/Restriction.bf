using System;
using System.Collections;
using System.Diagnostics;

using Xml;
using Regex;

namespace Xml.Schema;

abstract class Restriction
{
	public abstract Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc);
	public bool fixedForChildren = false;
	protected mixin Assert(bool condition)
	{
		if (!condition)
			return .Err;
	}
}

class LengthRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int length = Try!(int.Parse(value));
		Assert!(length >= 0);
		type.rules.Add(new:alloc (str) => str.Length == length);
		return .Ok;
	}
}

class MinLengthRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int length = Try!(int.Parse(value));
		Assert!(length >= 0);
		type.rules.Add(new:alloc (str) => str.Length >= length);
		return .Ok;
	}
}

class MaxLengthRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int length = Try!(int.Parse(value));
		Assert!(length >= 0);
		type.rules.Add(new:alloc (str) => str.Length <= length);
		return .Ok;
	}
}

class EnumerationRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		type.enumeration.Add(value);
		return .Ok;
	}
}

class PatternRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		Runtime.NotImplemented();
	}
}

class BoundRestriction : Restriction, this(Mode mode, bool floatingPoint)
{
	public enum Mode
	{
		MaxInclusive,
		MaxExclusive,
		MinInclusive,
		MinExclusive,
	}

	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int iBound = ?;
		double dBound = ?;
		if (floatingPoint)
			dBound = Try!(double.Parse(value));
		else
			iBound = Try!(int.Parse(value));
		mixin Bound()
		{
			floatingPoint ? dBound : iBound
		}
		Assert!(Bound!() >= 0);
		switch (mode)
		{
		case .MaxInclusive:
			type.rules.Add(new:alloc (str) => int.Parse(str) <= Bound!());
		case .MaxExclusive:
			type.rules.Add(new:alloc (str) => int.Parse(str) <  Bound!());
		case .MinInclusive:
			type.rules.Add(new:alloc (str) => int.Parse(str) >= Bound!());
		case .MinExclusive:
			type.rules.Add(new:alloc (str) => int.Parse(str) >  Bound!());
		}

		return .Ok;
	}
}

class MaxInclusiveRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int bound = Try!(int.Parse(value));
		Assert!(bound >= 0);
		type.rules.Add(new:alloc (str) => int.Parse(str) <= bound);
		return .Ok;
	}
}

class WhiteSpaceRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		switch (value)
		{
		case "preserve":
		case "replace":
			type.edits.Add(new:alloc (str) =>
				{
					for (let char in str.RawChars)
						if (char.IsWhiteSpace)
							str[@char.Index] = ' ';
				});
		case "collapse":
			type.edits.Add(new:alloc (str) =>
			{
				str.Trim();
				int length = str.Length;
				bool wasWhitespace = false;
				for (int i = 0; i < length; i++)
				{
					if (str[i].IsWhiteSpace)
					{
						if (!wasWhitespace)
							str[i] = ' ';
						else
						{
							str.Remove(i--);
							length--;
						}
						wasWhitespace = true;
					}
					else wasWhitespace = false;
				}
			});
		default:
			return .Err;
		}

		return .Ok;
	}
}

class TotalDigitsRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int expected = Try!(int.Parse(value));
		Assert!(expected >= 0);
		type.rules.Add(new:alloc (str) =>
			{
				int found = 0;
				for (let c in str)
					if (c.IsWhiteSpace)
						found++;
				return expected == found;
			});
		return .Ok;
	}
}

class FractionDigitsRestriction : Restriction
{
	public override Result<void> Init(AnySimpleType type, StringView value, BumpAllocator alloc)
	{
		int expected = Try!(int.Parse(value));
		Assert!(expected >= 0);
		type.rules.Add(new:alloc (str) =>
			{
				int found = 0;
				bool foundDot = false;
				for (let c in str)
				{
					if (c == '.') foundDot = true;
					if (c.IsWhiteSpace && foundDot)
						found++;
				}
				return expected >= found;
			});
		return .Ok;
	}
}
