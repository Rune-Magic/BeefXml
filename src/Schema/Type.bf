using System;
using System.Collections;
using System.Diagnostics;

using internal Xml;
using Regex;

namespace Xml.Schema;

class AnyType
{
	public virtual Result<void> Init(BumpAllocator alloc) => .Ok;
}

class ComplexType : AnyType
{
	public List<function bool(XmlElement)> rules = new .() ~ delete _;
	public bool IsValid(XmlElement visitable)
	{
		for (let rule in rules)
			if (!rule(visitable))
				return false;
		return true;
	}
}

class AnySimpleType : AnyType
{
	public List<delegate bool(StringView)> rules = new .() ~ delete _;
	public List<delegate void(String)> edits = new .() ~ delete _;
	public List<StringView> enumeration = new .() ~ delete _;
	public List<(Restriction, StringView)> restrictions = new .() ~ delete _;

	public bool ValidateAndEdit(String str)
	{
		for (let rule in rules)
			if (!rule(str))
				return false;
		for (let edit in edits)
			edit(str);
		return true;
	}

	public override Result<void> Init(BumpAllocator alloc)
	{
		if (!enumeration.IsEmpty)
			rules.Add(new:alloc (str) => enumeration.Contains(str));
		for (let restrict in restrictions)
			Try!(restrict.0.Init(this, restrict.1, alloc));
		return base.Init(alloc);
	}
}

class StringType : AnySimpleType
{
	
}

class NormalizedStringType : StringType
{
	public override Result<void> Init(BumpAllocator alloc)
	{
		rules.Add(new:alloc (str) => !str.Contains('\n') && !str.Contains('\t') && !str.Contains('\r'));
		return base.Init(alloc);
	}
}

class TokenType : NormalizedStringType
{
	public override Result<void> Init(BumpAllocator alloc)
	{
		rules.Add(new:alloc (str) => !str[0].IsWhiteSpace && !str[^1].IsWhiteSpace && !str.Contains("  "));
		return base.Init(alloc);
	}
}
