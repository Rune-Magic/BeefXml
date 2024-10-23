using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using System.Globalization;
using internal Xml;

namespace Xml;

class XmlReader : this(MarkupSource source, Options flags = .SkipWhitespace | .RequireSemicolon | .Trim | .ValidateChars), SourceProvider
{
	public enum Options : uint8
	{
		None = 0,
		/// skip empty character data (only whitespace)
		SkipWhitespace = 1,
		/// trim leading whitespace of character data
		TrimStart = _*2,
		/// trim trailing whitespace of character data
		TrimEnd = _*2,
		/// trim leading whitespace of a line in character data
		TrimLeading = _*2,
		/// trim trailing whitespace of a line character data
		TrimTrailing = _*2,
		/// requires entities to end with a semicolon
		RequireSemicolon = _*2,
		/// checks if chars are valid the respective xml version
		/// only disable this if you are working with generated xml files as a pose to man-made ones
		ValidateChars = _*2,

		TrimCData = .TrimEnd | .TrimStart,
		TrimLines = .TrimLeading | .TrimTrailing,
		Trim = .TrimCData | .TrimLines,
	}

	internal BumpAllocator alloc = new .() ~ delete _;

	Dictionary<String, MarkupUri> parsedEntities = null;
	Dictionary<String, String> rawEntities = null;
	Queue<XmlVisitable> cached = new .() ~ delete _;

	public override MarkupSource DefaultSource => source;

	XmlVersion version = .V1_0;

	MarkupSource.Index startIdx = default;
	public void Error(StringView errMsg, params Object[] formatArgs)
	{
		if (startIdx == default || startIdx.line != Source.CurrentIdx.line)
		{
			Source.Error(errMsg, params formatArgs);
			return;
		}
		Source.[Friend]ErrorNoIndexNoNewLine(errMsg, params formatArgs);
		source.[Friend]WriteIndex(startIdx, Source.CurrentIdx.col - startIdx.col);
		Debug.Break();
	}

	/// will make the passed node returned by the next ParseNext call
	public void Cycle(XmlVisitable node)
	{
		cached.Add(node);
	}

	mixin EnsureNmToken(char32 c)
	{
		if (flags.HasFlag(.ValidateChars))
			Util.EnsureNmToken!(c, version, Source);
	}

	public Result<XmlHeader> ParseHeader()
	{
		XmlHeader output = .(.V1_1, .UTF_8, false, null, null);

		mixin Expect(StringView str)
		{
			if (!Source.Consume(str))
			{
				Source.Error($"Expected '{str}'");
				return .Err;
			}
		}

		bool xmlDecl = false;
		while (true)
		{
			while (Try!(ClearComment())) {}
			Expect!("<");

			if (Source.Consume('?'))
			{
				Expect!("xml");
				if (xmlDecl)
				{
					Source.Error("Duplicate xml deceleration");
					return .Err;
				}
				inTagDef = true;
				xmlDecl = true;
				String key, value;
				XmlVisitable arg;
				while (!Source.Consume("?", ">"))
				{
					arg = Try!(ParseNext());
					if (!(arg case .Attribute(out key, out value)))
					{
						Source.Error("Expected attribute or '?>'");
						return .Err;
					}

					switch (key)
					{
					case "version":
						switch (value)
						{
						case "1.0": output.version = .V1_0;
						case "1.1": output.version = .V1_1;
						default:
							output.version = .Unknown(value);
							continue;
						}
					case "encoding":
						switch (value)
						{
						case "UTF-8": output.encoding = .UTF_8;
						case "UTF-16": output.encoding = .UTF_16;
						default:
							output.encoding = .Other(value);
							continue;
						}
					case "standalone":
						switch (value)
						{
						case "yes": output.standalone = true;
						case "no": output.standalone = false;
						default:
							Source.Error("Invalid standalone, expected 'yes' or 'no'");
							return .Err;
						}
					default:
						Source.Error($"Unknown declaration attribute: {key}");
						return .Err;
					}
				}

				inTagDef = false;
				continue;
			}

			if (Source.Consume('!'))
			{
				Expect!("DOCTYPE");
				if (output.doctype != null)
				{
					Source.Error("Duplicate DOCTYPE");
					return .Err;
				}

				parsedEntities = new:alloc .(4);
				rawEntities = new:alloc .(4);

				Source.ConsumeWhitespace();
				String root = new:alloc .(8);
				char32 c;
				while (true)
				{
					if (!Source.PeekNext(out c, let length)) break;
					if (c.IsWhiteSpace || (length == 1 && "<>[]'\"".Contains((char8)c))) break;
					Source.MoveBy(length);
					root.Append(c);
				}
				output.rootNode = root;
				
				if (Source.Consume('['))
					output.doctype = Try!(Doctype.Parse(Source, alloc, true));
				else
				{
					MarkupUri uri = .Parse(Source, alloc);
					let stream = Try!(uri.Open(source));
					MarkupSource src = scope .(scope .(stream), uri.Name);
					output.doctype = Try!(Doctype.Parse(src, alloc));
					output.doctype.Origin = uri;
					stream.Close(); delete stream;
					Expect!(">");
				}

				for (let entity in output.doctype.entities)
				{
					switch (entity.value.contents)
					{
					case .Parsed(let uri):
						parsedEntities.Add(entity.key, uri);
					case .General(let data):
						rawEntities.Add(entity.key, data);
					case .Notation:
						rawEntities.Add(entity.key, entity.value.contents.GetRawData(..new:alloc .(), source));
					}
				}

				Expect!(">");
				continue;
			}

			break;
		}

		return output;
	}

	/// @return if a comment were cleared
	[NoDiscard]
	private Result<bool> ClearComment()
	{
		if (!Source.Consume("<", "!", "--"))
			return false;
		while (!Source.Consume("--", ">"))
		{
			if (!Source.PeekNext(?, let length))
			{
				Source.Error("Comment was not closed");
				return .Err;
			}

			Source.MoveBy(length);
		}
		return true;
	}

	bool inTagDef = false;

	/// @brief parses the next xml element
	/// @param expectRoot used after parsing the header, implies a '<'
	public XmlVisitable ParseNext(bool expectRoot = false)
	{
		if (!cached.IsEmpty)
			return cached.PopFront();

		while (Try!(ClearComment())) {}
		Source.ConsumeWhitespace();

		startIdx = Source.CurrentIdx;

		if (Source.Ended)
		{
			if (!PopSource())
				return .EOF;
			blockedEntities.PopFront();
		}
		
		if (inTagDef)
		{
			if (expectRoot)
			{
				Source.Error("Expected root tag");
				return .Err;
			}

			if (Source.Consume("/", ">")) { inTagDef = false; return .OpeningEnd(true); }
			if (Source.Consume(">")) { inTagDef = false; return .OpeningEnd(false); }

			String name = new:alloc .();
			char32 c;
			Source.ConsumeWhitespace();
			while (true)
			{
				if (!Source.PeekNext(out c, let length))
					break;

				if (c.IsWhiteSpace || c == '=')
					break;

				EnsureNmToken!(c);

				name.Append(c);
				Source.MoveBy(length);
			}
			if (!Source.Consume('='))
			{
				Source.Error("Expected '='");
				return .Err;
			}
			char8 quote;
			if (Source.Consume('"')) quote = '"';
			else if (Source.Consume('\'')) quote = '\'';
			else
			{
				Source.Error("Expected double or single quote");
				return .Err;
			}
			switch (ParseCharacterData(quote))
			{
			case .CharacterData(let data):
				return .Attribute(name, data);
			case .Err:
				return .Err;
			default:
				Internal.FatalError("ParseCharacterData return invalid result, this is a bug");
			}
		}
		else
		{
			if (expectRoot || Source.Consume('<'))
			{
				String builder = new:alloc .();
				char32 c;
				let endTag = Source.Consume('/');
				Source.ConsumeWhitespace();
				bool first = true;
				while (true)
				{
					if (!Source.PeekNext(out c, let length))
						break;

					if (c.IsWhiteSpace || c == '/' || c == '>')
						break;

					EnsureNmToken!(c);

					first = false;
					builder.Append(c);
					Source.MoveBy(length);
				}

				if (endTag)
				{
					if (!Source.Consume('>'))
					{
						Source.Error("Expected '>'");
						return .Err;
					}
					return .ClosingTag(builder);
				}

				inTagDef = true;
				return .OpeningTag(builder);
			}

			if (expectRoot)
			{
				Source.Error("Expected root tag");
				return .Err;
			}

			return ParseCharacterData();
		}
	}

	Queue<String> blockedEntities = new .() ~ delete _;
	protected XmlVisitable ParseCharacterData(char8 quote = 0)
	{
		bool terminateOnQuote = quote != 0;

		Result<String> HandleEntity()
		{
			String builder = scope .(16);
			char32 c;
			bool digit = false, hex = false;
			int i = 0;
			Source.MoveBy(1);
			loop: while (true)
			{
				if (!Source.PeekNext(out c, let length))
				{
					if (!flags.HasFlag(.RequireSemicolon)) break loop;
					Source.Error("Invalid entity, expected semicolon");
					return .Err;
				}

				Source.MoveBy(length);
				defer { i++; }

				if (c == ';')
					break loop;

				if (c.IsWhiteSpace)
				{
					if (!builder.IsEmpty && !flags.HasFlag(.RequireSemicolon))
						break loop;
					Source.Error("Invalid entity, expected semicolon");
					return .Err;
				}

				do
				{
					if (i == 0)
					{
						hex = c == '#';
						digit = hex;
						if (hex) continue;
					}
					else if (i == 1)
					{
						hex = hex && c == 'x';
						if (hex) continue;
					}

					if (!c.IsNumber)
					{
						if (digit && !hex) break;
						digit = false;
						hex = hex && (length == 1 && "ABCDEFabcdef".Contains((char8)c));
						builder.Append(c);
						continue;
					}

					EnsureNmToken!(c);
					builder.Append(c);
					continue;
				}

				Source.Error("Invalid entity");
				return .Err;
			}

			mixin HandleParseResult(Result<uint32, UInt32.ParseError> result)
			{
				switch (result)
				{
				case .Ok(let val):
					if (version case .V1_1)
					{
						if (val == 0x85 || val == 0x2028)
							return "\n";
					}
					return new:alloc String(sizeof(char32))..Append(char32(val));
				case .Err(let err):
					Source.Error($"Invalid entity, Error while parsing \"{new:alloc String(builder)}\": {err}");
					return .Err;
				}
			}

			if (hex)
				HandleParseResult!(uint32.Parse(builder, .Hex));
			if (digit)
				HandleParseResult!(uint32.Parse(builder, .Integer));

			if (parsedEntities != null && parsedEntities.TryGet(builder, ?, let value))
			{
				String uri;
				switch (value)
				{
				case .System(out uri), .Public(?, out uri):
				case .Raw:
					Internal.FatalError("Raw entity data cannot be parsed (code is broken)");
				}
				Source = new .(new .(Try!(value.Open(Source))), uri);
				return .Ok(.Empty);
			}
			else if (rawEntities != null && rawEntities.TryGet(builder, ?, let value))
				return value;
			switch (Util.MatchBaseXmlEntity(builder))
			{
			case .Ok(let val): return val;
			case .Err:
				Source.Error($"Entity {new:alloc String(builder)} not found");
				return .Err;
			}
		}

		String builder = new:alloc .(32);
		char32 c;
		bool cdata = false;
		bool whitespace = !terminateOnQuote;
		bool lineWhitespace = true;
		loop: while (Source.PeekNext(out c, let length))
		{
			if (!c.IsWhiteSpace)
			{
				whitespace = false;
				lineWhitespace = false;
				if (!cdata)
					switch (c)
					{
					case '\'', '"':
						if (!terminateOnQuote || c != quote) break;
						Source.MoveBy(length);
						break loop;
					case '>' when !terminateOnQuote:
						if (c == quote) fallthrough;
						Source.Error($"Usage of reserved character: {c}");
						return .Err;
					case '&':
						builder.Append(Try!(HandleEntity()));
						continue;
					case '<':
						if (Try!(ClearComment()))
							continue;
						if (!Source.Consume("<", "!", "[", "CDATA", "["))
						{
							if (terminateOnQuote)
							{
								/*source.PushError("Usage of reserved character: <");
								return .Err;*/
								continue;
							}
							break loop;
						}
						cdata = true;
						continue;
					}
				else
					switch (c)
					{
					case ']':
						if (!Source.Consume("]", "]", ">")) break;
						cdata = false;
						continue;
					}
			}
			else if (c == '\n')
			{
				lineWhitespace = true;
				if (flags.HasFlag(.TrimTrailing))
					builder.TrimEnd();
				builder.Append('\n');
				Source.MoveBy(1);
				continue;
			}

			if (flags.HasFlag(.ValidateChars))
				Util.EnsureChar!(c, version, Source);

			if ((!whitespace || !flags.HasFlag(.TrimStart)) && (!lineWhitespace || !flags.HasFlag(.TrimLeading)))
				builder.Append(c);
			Source.MoveBy(length);
		}

		if ((whitespace && flags.HasFlag(.SkipWhitespace)) || builder.IsEmpty)
			return ParseNext();
		if (flags.HasFlag(.TrimEnd))
			builder.TrimEnd();
		return .CharacterData(builder);
	}
}

internal class SourceProvider
{
	public Queue<MarkupSource> SourceOverride = new .() ~ delete _;
	public virtual MarkupSource DefaultSource { get; set; }

	public MarkupSource Source
	{
		get
		{
			if (SourceOverride.IsEmpty)
				return DefaultSource;
			return SourceOverride.Front;
		}

		set
		{
			value.ErrorStream = DefaultSource.[Friend]ErrorStream;
			SourceOverride.AddFront(value);
		}
	}

	public Result<void> OpenSource(MarkupUri uri)
	{
		let stream = Try!(uri.Open(DefaultSource));
		SourceOverride.Add(new .(new .(stream), uri.Name));
		return .Ok;
	}

	public bool PopSource()
	{
		if (SourceOverride.IsEmpty) return false;
		let source = SourceOverride.PopFront();
		source.Stream.BaseStream.Close();
		source.Stream.[Friend]mOwnsStream = true;
		delete source.Stream;
		delete source;
		return true;
	}
}