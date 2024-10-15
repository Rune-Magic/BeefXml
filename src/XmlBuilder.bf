using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Xml;

class XmlBuilder
{
	enum Options
	{
		None = 0,
		// will indent
		Format = 1,
		// will indent c data
		FormatCData = _*2,
	}

	bool ownsStream = false;
	StreamWriter stream;
	Options flags;

	public StringView IndentStr { protected get; set; } = "    ";

	public this(StreamWriter stream, Options options = .Format | .FormatCData)
	{
		this.stream = stream;
		this.flags = options;
	}

	int indent = 0;

	private mixin Write(var data)
	{
		Try!(stream.Write(data));
	}

	private mixin WriteLine(var data)
	{
		Try!(stream.Write(data));
		if (flags.HasFlag(.Format)) 
			Try!(stream.WriteLine());
	}

	private mixin WriteLine()
	{
		if (flags.HasFlag(.Format)) 
			Try!(stream.WriteLine());
	}

	protected Result<void> WriteLine()
	{
		if (!flags.HasFlag(.Format))
			return .Ok;
		Write!("\n");
		for (int i < indent)
			Write!(IndentStr);
		return .Ok;
	}

	bool onelineCData = false;
	bool justClosed = false;
	String tempBuffer = new .(4) ~ delete _;
	public Result<void> Write(XmlVisitable node)
	{
		switch (node)
		{
		case .Err:
			Internal.FatalError("Cannot write error node");
		case .EOF:
		case .Attribute(let key, let value):
			Try!(stream.Write($" {key}=\"{value}\""));
		case .CharacterData(let data):
			if ((!data.Contains('\n') && !justClosed) || !flags.HasFlag(.FormatCData))
			{
				onelineCData = true;
				for (var char in data.DecodedChars)
				{
					switch (Util.MatchBaseXmlEntity(char))
					{
					case .Err:
						tempBuffer.Clear();
						char.ToString(tempBuffer);
						Write!(tempBuffer);
					case .Ok(let val): Write!(val);
					}
				}
				break;
			}
			for (let line in data.Split('\n'))
			{
				onelineCData = false;
				Try!(WriteLine());
				for (let char in line.DecodedChars)
				{
					switch (Util.MatchBaseXmlEntity(char))
					{
					case .Err:
						tempBuffer.Clear();
						char.ToString(tempBuffer);
						Write!(tempBuffer);
					case .Ok(let val): Write!(val);
					}
				}
			}
		case .OpeningTag(let name):
			Try!(WriteLine());
			Try!(stream.Write($"<{name}"));
		case .OpeningEnd(let bodyless):
			if (bodyless)
			{
				justClosed = true;
				Write!(" />");
			}
			else
			{
				justClosed = false;
				Write!(">");
				indent++;
			}
		case .ClosingTag(let name):
			indent--;
			justClosed = true;
			if (!onelineCData) Try!(WriteLine());
			onelineCData = false;
			Try!(stream.Write($"</{name}>"));
		}

		return .Ok;
	}

	public Result<void> Write(Doctype doctype)
	{
		StringView indentStr = "";
		if (indent > 0)
			indentStr = IndentStr;

		bool empty = true;
		mixin NewLine()
		{
			if (!empty && flags.HasFlag(.Format)) Try!(WriteLine());
			empty = true;
		}

		for (let notation in doctype.notations)
		{
			empty = false;
			Try!(stream.Write($"{IndentStr}<!NOTATION {notation.key} {notation.value}>"));
			WriteLine!();
		}
		NewLine!();

		for (let entity in doctype.entities)
		{
			empty = false;
			Try!(stream.Write($"{IndentStr}<!ENTITY "));
			if (entity.value.parameter) Write!("% ");
			switch (entity.value.contents)
			{
			case .General(let data):
				Try!(stream.Write($"{entity.key} {MarkupUri.Raw(data)}"));
			case .Notation(let notation, let uri):
				Try!(stream.Write($"{entity.key} {uri} NDATA {MarkupUri.Raw(notation)}"));
			case .Parsed(let uri):
				Try!(stream.Write($"{entity.key} {uri}"));
			}
			WriteLine!(">");
		}
		NewLine!();

		for (let element in doctype.elements)
		{
			NewLine!();
			empty = false;
			element: do
			{
				Try!(stream.Write($"{IndentStr}<!ELEMENT {element.key} "));
				switch (element.value.contents)
				{
				case .PCData:
					Write!("(#PCDATA)>");
					break element;
				case .Child(let name):
					Try!(stream.Write($"({name})>"));
				case .Optional(let element):
					if (element case .Child(let name))
					{
						Try!(stream.Write($"({name})?>"));
						break element;
					}
				case .ZeroOrMore(let element):
					if (element case .Child(let name))
					{
						Try!(stream.Write($"({name})*>"));
						break element;
					}
				case .OneOrMore(let element):
					if (element case .Child(let name))
					{
						Try!(stream.Write($"({name})+>"));
						break element;
					}
				default:
				}
				Try!(stream.Write($"{element.value.contents}>"));
			}
			WriteLine!();
			for (let attlist in element.value.attlists)
			{
				Try!(stream.Write($"{IndentStr}<!ATTLIST {element.key} {attlist.key} {attlist.value.type} {attlist.value.value}>"));
				WriteLine!();
			}
		}

		return .Ok;
	}

	public Result<void> Write(XmlHeader header, MarkupUri? customUri = null)
	{
		if (!flags.HasFlag(.Format)) IndentStr = "";

		Write!("<?xml version=\"");
		switch (header.version)
		{
		case .V1_0: Write!("1.0");
		case .V1_1: Write!("1.1");
		case .Unknown(let p0): Write!(p0);
		}

		Write!("\" encoding=\"");
		switch (header.encoding)
		{
		case .UTF_8: Write!("UTF-8");
		case .UTF_16: Write!("UTF-16");
		case .Other(let p0): Write!(p0);
		}

		Try!(stream.Write("\" standalone=\"{}\"?>", header.standalone ? "yes" : "no"));

		if (header.doctype == null && customUri == null) return .Ok;

		WriteLine!();
		Try!(stream.Write($"<!DOCTYPE {header.rootNode} "));
		if (customUri != null)
		{
			Try!(stream.Write($"{customUri.Value}>"));
			WriteLine!();
			return .Ok;
		}
		if (header.doctype.Origin != null)
		{
			Try!(stream.Write($"{header.doctype.Origin.Value}>"));
			WriteLine!();
			return .Ok;
		}

		indent++;
		WriteLine!("[");
		Try!(Write(header.doctype));
		Write!("]>");
		indent--;

		return .Ok;
	}

	public Result<void> Write(XmlElement element)
	{
		if (element.PrecedingText != null)
			Try!(Write(.CharacterData(element.PrecedingText)));
		Try!(Write(.OpeningTag(element.Name)));

		for (let attr in element.Attributes)
			Try!(Write(.Attribute(attr.key, attr.value)));

		if (element.Children.IsEmpty && element.FooterText.IsEmpty)
		{
			Try!(Write(.OpeningEnd(true)));
			return .Ok;
		}

		Try!(Write(.OpeningEnd(false)));
		for (let child in element.Children)
			Try!(Write(child));

		if (element.FooterText != null)
			Try!(Write(.CharacterData(element.FooterText)));
		Try!(Write(.ClosingTag(element.Name)));

		return .Ok;
	}
}