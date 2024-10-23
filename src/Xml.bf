using System;
using System.IO;
using System.Diagnostics;
using System.Collections;

namespace Xml;

enum XmlVisitable
{
	/// indicates that something went wrong, the error will be stored on the MarkupSource
	case Err(void);

	/// eg. <Example
	case OpeningTag(String name);

	/// either '>' or '/>'
	case OpeningEnd(bool bodyless);

	/// eg. </Example>
	case ClosingTag(String name);

	/// regular text or CDATA
	case CharacterData(String data);

	/// eg. example="example value"
	case Attribute(String key, String value);

	/// end of file
	case EOF;

	// support Try!
	[NoShow(false), Inline]
	public Self Get() => this;

	public override void ToString(String strBuffer)
	{
		switch (this)
		{
		case .Err:
			strBuffer.Append("<error>");
		case .OpeningTag(let name):
			if (name == null)
				strBuffer.Append("element");
			else
				strBuffer.Append("element ", name);
		case .OpeningEnd(let bodyless):
			strBuffer.Append('\'');
			if (bodyless) strBuffer.Append('/');
			strBuffer.Append(">'");
		case .ClosingTag(let name):
			if (name == null)
				strBuffer.Append("closing tag");
			else
				strBuffer.Append("closing tag for ", name);
		case .CharacterData:
			strBuffer.Append("character data");
		case .Attribute(let key, let value):
			if (key == null)
				strBuffer.Append("attribute");
			else if (value == null)
				strBuffer.Append("attribute ", key);
			else
				strBuffer.Append("attribute ", key, " with value '", value, "'");
		case .EOF:
			strBuffer.Append("end of file");
		}
	}
}

enum XmlVersion
{
	case V1_0, V1_1, Unknown(String);
}

enum XmlEncoding
{
	case UTF_8, UTF_16, Other(String);
}

/// holder info specified before the root node eg. the doctype the encoding etc.
/// @param version bold
struct XmlHeader : this(
	XmlVersion version,
	XmlEncoding encoding,
	bool standalone,
	Doctype doctype,
	String rootNode
);

/// provides basic functionality for Xml parsing
static class Xml
{
	public static mixin Open(StringView path)
	{
		StreamReader reader = scope:mixin .();
		reader.Open(path) case .Err(let err)
			? Result<XmlReader, FileOpenError>.Err(err)
			: Result<XmlReader, FileOpenError>.Ok(scope:mixin XmlReader(scope:mixin .(reader, path)))
	}

	public static Result<TResult> FetchResult<TVisitor, TResult>(TVisitor visitor, XmlReader reader) where TVisitor : XmlVisitor, IResultVisitor<TResult>
	{
		XmlVisitorPipeline pipeline = scope .(visitor);
		Try!(pipeline.Run(reader));
		return visitor.Result;
	}
}

internal static class Util
{
	public static Result<String> MatchBaseXmlEntity(StringView str)
	{
		switch (str.GetHashCode())
		{
		case "amp".[ConstEval]GetHashCode(): return "&"; 
		case "lt".[ConstEval]GetHashCode(): return "<"; 
		case "gt".[ConstEval]GetHashCode(): return ">"; 
		case "apos".[ConstEval]GetHashCode(): return "\'"; 
		case "quot".[ConstEval]GetHashCode(): return "\""; 
		}

		return .Err;
	}

	public static Result<String> MatchBaseXmlEntity(char32 c)
	{
		switch (c)
		{
		case '&': return "&amp;";
		case '<': return "&lt;";
		case '>': return "&gt;";
		case '\'': return "&apos;";
		case '"': return "&quot;";
		}

		return .Err;
	}

	public const let NmTokenStartCharEBNF = "";
	public const let NmTokenCharEBNF = NmTokenStartCharEBNF + "";

	[Comptime]
	public static void ParseAndEmitEBNFEnumaration(StringView ebnf, String onFail = """
				source.Error($"char '{c}' is not valid");
				return .Err;
			""")
	{
		String builder = scope .("if (!(");

		void ParseElement(String element)
		{
			Result<uint32> DecodeHex(String from)
			{
				if (!from.StartsWith("#x")) return .Err;
				from.Remove(0, 2);
				return .Ok(.Parse(from, .Hex));
			}

			if (element.StartsWith('\''))
			{
				var iter = element.DecodedChars;
				iter.MoveNext();
				builder.AppendF($"c == (.){(uint32)iter.GetNext()}u");
				return;
			}

			if (DecodeHex(element) case .Ok(let val))
			{
				builder.AppendF($"c == (.){val}u");
				return;
			}

			// we are in [a-z] notation
			element.Remove(0);
			element.RemoveFromEnd(1);

			var iter = element.Split('-', 2);
			String first = scope .(iter.GetNext()); first.Trim();
			String second = scope .(iter.GetNext()); second.Trim();

			builder.Append("c >= (.)");
			if (first.Length > 1)
				DecodeHex(first)->ToString(builder);
			else
				((uint8)first[0]).ToString(builder);

			builder.Append("u && c <= (.)");
			if (second.Length > 1)
				DecodeHex(second)->ToString(builder);
			else
				((uint8)second[0]).ToString(builder);

			builder.Append("u");
		}

		for (let element in ebnf.Split('|'))
		{
			String copy = scope .(element);
			copy.Trim();
			builder.Append('(');
			ParseElement(copy);
			builder.Append(')');
			builder.Append(" || \n\t");
		}

		builder.RemoveFromEnd(6);
		builder.Append("))\n{\n", onFail, "\n}");

		Compiler.MixinRoot(builder);
	}

	public static mixin EnsureNmToken(char32 c, XmlVersion version, MarkupSource source)
	{
		if (!(version case .Unknown))
			ParseAndEmitEBNFEnumaration(
				"':' | [A-Z] | '_' | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] | [#x370-#x37D] | [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] | [#x2C00-#x2FEF] | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD] | [#x10000-#xEFFFF] | '-' | '.' | [0-9] | #xB7 | [#x0300-#x036F] | [#x203F-#x2040]"
			);
	}

	public static mixin EnsureChar(char32 c, XmlVersion version, MarkupSource source)
	{
		switch (version)
		{
		case .V1_0:
			ParseAndEmitEBNFEnumaration(
				"#x9 | #xA | #xD | [#x20-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]"
			);
		case .V1_1:
			ParseAndEmitEBNFEnumaration(
				"[#x1-#xD7FF] | [#xE000-#xFFFD] | [#x10000-#x10FFFF]"
			);
		default:
		}
	}
}
