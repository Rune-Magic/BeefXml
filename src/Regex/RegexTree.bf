using System;
using System.Text;
using System.Collections;
using System.Diagnostics;

namespace Regex;

abstract class RegexTreeNode
{
	protected struct PassInfo : this(StringView original, int offset, Queue<PassInfo> looseEnds);
	protected abstract Result<int> Consume(StringView string, ref PassInfo info);

	public bool Matches(StringView string)
	{
		PassInfo info = .(string, 0, scope .());
		while (true)
		{
			if (Consume(.(string, info.offset), ref info) case .Ok) return true;
			if (info.looseEnds.IsEmpty) return false;
			info = info.looseEnds.PopBack();
		}
	}
}

class RegexSequence : RegexTreeNode
{
	public List<RegexTreeNode> children;
	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		int start = info.offset;
		for (let child in children)
			switch (child.[Friend]Consume(.(info.original, info.offset), ref info))
			{
			case .Ok(let val):
				if (info.offset + val >= string.Length)
					return .Err;
				info.offset += val;
			case .Err:
				info.offset = start;
				return .Err;
			}
		return 0;
	}

	public override void ToString(String strBuffer)
	{
		strBuffer.Append("sequence");
	}
}

class RegexCharacterNode : RegexTreeNode
{
	public char32 char;
	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		if (string.IsEmpty) return .Err;
		(let c, let length) = UTF8.Decode(string.Ptr, string.Length);
		if (c != char) return .Err;
		return length;
	}

	public override void ToString(String strBuffer)
	{
		strBuffer.AppendF($"'{char}'");
	}
}

class RegexAnchorNode : RegexTreeNode
{
	public enum Type
	{
		StartLine,		// ^
		EndLine,		// $
		StartString,	// \A
		EndString,		// \Z
		WordBoundary,	// \b
		NoWordBoundary,	// \B
		WordStart,		// \<
		WordEnd,		// \>
	}

	public Type type;

	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		mixin Assert(bool condition)
		{
			if (!condition)
				return .Err;
		}

		mixin LastChar()
		{
			info.original[info.offset - 1]
		}

		switch (type)
		{
		case .StartLine:
			Assert!(info.offset == 0 || LastChar!() == '\n' || LastChar!() == '\f');
		case .StartString:
			Assert!(info.offset == 0);
		case .EndLine:
			Assert!(string.IsEmpty || string[0] == '\n' || string[0] == '\f' || (string.Length >= 2 && string[0] == '\r' && string[1] == '\n'));
		case .EndString:
			Assert!(string.IsEmpty);
		case .WordBoundary:
			Self inst = scope .() { type = .WordStart };
			if (inst.Consume(string, ref info) case .Err)
			{
				inst.type = .WordEnd;
				Try!(inst.Consume(string, ref info));
			}
		case .NoWordBoundary:
			Assert!(info.offset != 0 && !string.IsEmpty);
			Assert!(((LastChar!().IsLetterOrDigit || LastChar!() == '_') &&  (string[0].IsLetterOrDigit || string[0] == '_'))
				|| (!(LastChar!().IsLetterOrDigit || LastChar!() == '_') && !(string[0].IsLetterOrDigit || string[0] == '_')));
		case .WordStart:
			Assert!(info.offset == 0 || !(LastChar!().IsLetterOrDigit || LastChar!() == '_'));
			Assert!(!string.IsEmpty && (string[0].IsLetterOrDigit || string[0] == '_'));
		case .WordEnd:
			Assert!(info.offset != 0 && (LastChar!().IsLetterOrDigit || LastChar!() == '_'));
			Assert!(string.IsEmpty || !(string[0].IsLetterOrDigit || string[0] == '_'));
		}

		return .Ok(0);
	}

	public override void ToString(String strBuffer)
	{
		type.ToString(strBuffer);
	}
}

class RegexPredefinedNode : RegexTreeNode
{
	public enum Type
	{
		Any,					// .
		Upper,					// [:upper:]
		Lower,					// [:lower:]
		Letter,					// [:alpha:]
		AlphaNumeric,			// [:alnum:]
		Digit,					// [:digit:]	\d
		HexDigit,				// [:xdigit:]	\x
		OctalDigit,				//				\O
		Punctuation,			// [:punct:]
		SpaceOrTab,				// [:blank:]
		Whitespace,				// [:space:]	\s
		Control,				// [:cntrl:]
		PrintedLetter,			// [:graph:]
		PrintedLetterOrSpace,	// [:print:]
		WordCharacter,			// [:word:]		\w
		NewLine,				//				\n

		NotWordCharacter,		// 				\W
		NotNewLine,				// 				\N
		NotDigit,				// 				\D

		XmlNmTokenStartChar,	//				\i
		XmlNmTokenChar,			//				\c
		NotXmlNmTokenStartChar,	//				\I
		NotXmlNmTokenChar,		//				\C
	}

	public Type type;

	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		if (string.IsEmpty) return .Err;
		(let c, let length) = UTF8.Decode(string.Ptr, string.Length);

		mixin ConsumeIf(bool condition)
		{
			if (condition)
				return .Ok(length);
			return .Err;
		}

		switch (type)
		{
		case .Any:			ConsumeIf!(c != '\n' && c != '\f' && length == 1);
		case .Upper:		ConsumeIf!(c.IsUpper);
		case .Lower:		ConsumeIf!(c.IsLower);
		case .Letter:		ConsumeIf!(c.IsLetter);
		case .AlphaNumeric:	ConsumeIf!(c.IsLetterOrDigit);
		case .Digit:		ConsumeIf!(c.IsNumber);
		case .HexDigit:		ConsumeIf!(c.IsNumber || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'));
		case .OctalDigit:	ConsumeIf!(c >= '0' && c <= '7');
		case .Punctuation:	ConsumeIf!("-!\"#$%&'()*+,./:;<=>?@[]^_`{|}~".Contains(string[0]));
		case .SpaceOrTab:	ConsumeIf!(c == ' ' || c == '\t');
		case .Whitespace:	ConsumeIf!(c.IsWhiteSpace);
		case .Control:		ConsumeIf!((c >= 0 && c <= (.)0x1F) || c == (.)0x7F);
		case .PrintedLetterOrSpace:
			if (c == ' ') return .Ok(length);
			fallthrough;
		case .PrintedLetter:	ConsumeIf!(c != ' ' && !((c >= 0 && c <= (.)0x1F) || c == (.)0x7F));
		case .WordCharacter:	ConsumeIf!( c.IsLetterOrDigit || c == '_');
		case .NotWordCharacter:	ConsumeIf!(!c.IsLetterOrDigit && c != '_');
		case .NotDigit:			ConsumeIf!(!c.IsNumber);

		case .NewLine:
			if (length != 1) return .Err;
			if (string.Length >= 2 && string[0] == '\r' && string[1] == '\n') return .Ok(2);
			ConsumeIf!(c == '\n');
		case .NotNewLine:
			if (length != 1) return .Ok(length);
			if (string.Length >= 2 && string[0] == '\r' && string[1] == '\n') return .Err;
			ConsumeIf!(c != '\n');
		}
	}

	public override void ToString(String strBuffer)
	{
		type.ToString(strBuffer);
	}
}

class RegexEnumeration : RegexTreeNode
{
	public List<RegexTreeNode> options;
	public bool negitive = false;
	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		for (let option in options)
			if (option.[Friend]Consume(string, ref info) case .Ok(let val))
				return val;
		return .Err;
	}

	public override void ToString(String strBuffer)
	{
		strBuffer.Append("enumeration");
	}
}

class RegexQuantifier : RegexTreeNode
{
	public enum Type
	{
		case Optional;				// ?
		case OneOrMore;				// +
		case ZeroOrMore;			// *
		case Range(ClosedRange);	// {x,y}
		case Exact(int);			// {n}
		case Until(int);			// {,x}
		case AtLeast(int);			// {x,}
	}

	public Type type;
	public RegexTreeNode child;
	public RegexTreeNode lazyStop = null;

	protected override Result<int> Consume(StringView string, ref PassInfo info)
	{
		int start = info.offset;
		mixin Ok() { return .Ok(0); }
		mixin Err() { info.offset = start; return .Err; }

		int i = 0;
		loop: while (true)
		{
			switch (type)
			{
			case .Optional:
				if (i == 1) Ok!();
			case .OneOrMore, .ZeroOrMore, .AtLeast:
			case .Range(let range):
				if (i == range.End) Ok!();
			case .Exact(var p), .Until(out p):
				if (i == p) Ok!();
			}

			if (lazyStop != null)
				switch (child.[Friend]Consume(.(info.original, info.offset), ref info))
				{
				case .Ok(let val):
					info.looseEnds.Add(info);
					info.offset += val; Ok!();
				case .Err:
				}

			switch (child.[Friend]Consume(.(info.original, info.offset), ref info))
			{
			case .Ok(let val):
				info.offset += val;
				i++;
			case .Err:
				break loop;
			}
		}

		switch (type)
		{
		case .Optional, .Until:
			Internal.FatalError(.Empty);
		case .ZeroOrMore:
		case .OneOrMore:
			if (i == 0) Err!();
		case .AtLeast(let p):
			if (i < p) Err!();
		case .Range(let range):
			if (i < range.Start) Err!();
		case .Exact(var p):
			if (i != p) Err!();
		}

		Ok!();
	}

	public override void ToString(String strBuffer)
	{
		strBuffer.AppendF($"{type} {child}");
	}
}
