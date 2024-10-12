using System;
using System.IO;
using System.Diagnostics;
using System.Collections;
using internal Xml;

namespace Xml;

class Doctype
{
	BumpAllocator alloc = new .() ~ delete _;
	public MarkupUri? Origin = null;

	public enum ElementContents
	{
		/// indicates that the type was not assigned yet, error on encounter 
		[NoShow] case Open;
		case AllOf(List<ElementContents> children);
		case AnyOf(List<ElementContents> children);
		case Empty, Any, PCData, CData;
		case Child(String name);
		case Optional(ElementContents* element);
		case OneOrMore(ElementContents* element);
		case ZeroOrMore(ElementContents* element);

		public static Result<Self> Parse(MarkupSource source, BumpAllocator alloc, XmlVersion version, bool root = true)
		{
			if (source.Consume('('))
			{
				const int8 Type_None = 0;
				const int8 Type_Or = 1;
				const int8 Type_And = 2;

				int8 type = Type_None;
				List<ElementContents> output = new:alloc .();

				bool pcdata = false, cdata = false;
				while (true)
				{
					output.Add(Try!(Parse(source, alloc, version, false)));
					switch (output.Back)
					{
					case .PCData:
						if (pcdata)
						{
							source.Error("Duplicate #PCDATA");
							return .Err;
						}
						pcdata = true;
					case .CData:
						if (cdata)
						{
							source.Error("Duplicate #CDATA");
							return .Err;
						}
						cdata = true;
					default:
					}
					if (source.Consume(')')) break;
					if (source.Consume('|'))
					{
						if (type == Type_And)
						{
							source.Error("Unexpected '|'");
							return .Err;
						}
						type = Type_Or;
						continue;
					}
					if (source.Consume(','))
					{
						if (type == Type_Or)
						{
							source.Error("Unexpected ','");
							return .Err;
						}
						type = Type_And;
						continue;
					}

					source.Error($"Unexpected '{source.PeekNext(..?, ?)}'");
					return .Err;
				}

				switch (type)
				{
				case Type_None:
					if (output.IsEmpty)
					{
						source.Error(new:alloc $"Expected element content");
						return .Err;
					}
					return .Ok(output[0]);
				case Type_And:
					return .Ok(.AllOf(output));
				case Type_Or:
					return .Ok(.AnyOf(output));
				}
			}

			if (root)
			{
				if (source.Consume("EMPTY"))
					return .Ok(.Empty);
				if (source.Consume("ANY"))
					return .Ok(.Any);
				source.Error("Expected '(', 'ANY' or 'EMPTY'");
				return .Err;
			}

			if (source.Consume("#CDATA"))
				return .Ok(.CData);
			if (source.Consume("#PCDATA"))
				return .Ok(.PCData);

			char32 c;
			String name = new:alloc .(16);
			while (true)
			{
				if (!source.PeekNext(out c, let length)) break;
				if (c.IsWhiteSpace || (length == 1 && ",?+<>|()'\"".Contains((char8)c))) break;
				Util.EnsureNmToken!(c, version, source);
				name.Append(c);
				source.MoveBy(length);
			}

			ElementContents child = .Child(name);
			mixin Package()
			{
				ElementContents *ptr = new:alloc .();
				*ptr = child;
				ptr
			}

			if (source.Consume('?'))
				return .Ok(.Optional(Package!()));
			else if (source.Consume('+'))
				return .Ok(.OneOrMore(Package!()));
			else if (source.Consume('*'))
				return .Ok(.ZeroOrMore(Package!()));

			return .Ok(child);
		}

		public override void ToString(String strBuffer)
		{
			switch (this)
			{
			case .AllOf(var list), .AnyOf(out list):
				if (list.IsEmpty)
				{
					strBuffer.Append("EMPTY");
					return;
				}
				strBuffer.Append('(');
				for (let child in list)
				{
					strBuffer.Append(child);
					if (@child.Index ==  list.Count - 1) break;
					if (this case .AllOf)
						strBuffer.Append(", ");
					else
						strBuffer.Append('|');
				}
				strBuffer.Append(')');
			case .Child(let name):
				strBuffer.Append(name);
			case .Optional(let element):
				element.ToString(strBuffer);
				strBuffer.Append('?');
			case .OneOrMore(let element):
				element.ToString(strBuffer);
				strBuffer.Append('+');
			case .ZeroOrMore(let element):
				element.ToString(strBuffer);
				strBuffer.Append('*');
			case .Any: strBuffer.Append("ANY");
			case .Empty: strBuffer.Append("EMPTY");
			case .PCData: strBuffer.Append("#PCDATA");
			case .CData: strBuffer.Append("#CDATA");
			case .Open:
				Internal.FatalError("Cannot convert unset element contents to a string");
			}
		}
	}

	public struct Attlist : this(AttributeType type, AttributeDefaultValue value)
	{
		public enum AttributeType
		{
			case CData, OneOf(List<String>), Notation(List<String>);
			case Id, IdRef, IdRefs, NmTokens, NmToken, Entity, Entities;

			public static Result<Self> Parse(MarkupSource source, BumpAllocator alloc, XmlVersion version)
			{
				bool notation = source.Consume("NOTATION");
				if (source.Consume('('))
				{
					List<String> options = new:alloc .(8) { new:alloc .(8) };
					char32 c;
					while (true)
					{
						if (!source.PeekNext(out c, let length))
						{
							source.Error("Expected ')'");
							return .Err;
						}
						source.MoveBy(length);
						if (c == '|')
						{
							options.Back.Trim();
							options.Add(new:alloc .(8));
							continue;
						}
						if (c == ')') break;
						if (notation && c.IsWhiteSpace)
						{
							if (source.Consume('|'))
							{
								options.Back.TrimStart();
								options.Add(new:alloc .(8));
								continue;
							}
							source.Error("Expected notation");
							return .Err;
						}
						Util.EnsureNmToken!(c, version, source);
						options.Back.Append(c);
					}
					if (notation)
						return .Ok(.Notation(options));
					return .Ok(.OneOf(options));
				}

				if (source.Consume("ENTITIES"))
					return .Ok(.Entities);
				if (source.Consume("ENTITY"))
					return .Ok(.Entity);
				if (source.Consume("CDATA"))
					return .Ok(.CData);
				if (source.Consume("NMTOKENS"))
					return .Ok(.NmToken);
				if (source.Consume("NMTOKEN"))
					return .Ok(.NmTokens);
				if (source.Consume("IDREFS"))
					return .Ok(.IdRefs);
				if (source.Consume("IDREF"))
					return .Ok(.IdRef);
				if (source.Consume("ID"))
					return .Ok(.Id);

				source.Error("Expected attribute type");
				return .Err;
			}

			public bool Matches(String input, HashSet<String> IDs, HashSet<String> IDREFs, Doctype self, XmlVersion version)
			{
				switch (this)
				{
				case CData: return true;
				case OneOf(let list):
					for (let option in list)
						if (input == option)
							return true;
					return false;
				case Id: // any other chars will be filtered out by the char validators (off by default)
					if (input.IsEmpty || input.Contains(' ') || input.Contains('\n') || input.Contains('\t') || input.Contains('\t')) return false;
					return IDs.Add(input);
				case IdRef:
					if (input.IsEmpty || input.Contains(' ') || input.Contains('\n') || input.Contains('\t') || input.Contains('\t')) return false;
					IDREFs.Add(input);
					return true;
				case IdRefs:
					for (let idref in input.Split(scope char8[](' ', '\n', '\t', '\r'), .RemoveEmptyEntries))
						IDREFs.Add(new:(self.alloc) .(idref));
					return true;
				case NmTokens:
					for (char32 c in input.DecodedChars)
					{
						Util.ParseAndEmitEBNFEnumaration(
							"':' | [A-Z] | '_' | [a-z] | [#xC0-#xD6] | [#xD8-#xF6] | [#xF8-#x2FF] | [#x370-#x37D] | [#x37F-#x1FFF] | [#x200C-#x200D] | [#x2070-#x218F] | [#x2C00-#x2FEF] | [#x3001-#xD7FF] | [#xF900-#xFDCF] | [#xFDF0-#xFFFD] | [#x10000-#xEFFFF] | '-' | '.' | [0-9] | #xB7 | [#x0300-#x036F] | [#x203F-#x2040]",
							"return false;"
						);
					}
					return !input.IsEmpty;
				case NmToken:
					return !(input.IsEmpty || input.Contains(' ') || input.Contains('\n') || input.Contains('\t') || input.Contains('\t'));
				case Entity:
					return self.entities.ContainsKey(input);
				case Entities:
					for (let entity in input.Split(scope char8[](' ', '\n', '\t', '\r'), .RemoveEmptyEntries))
						if (!self.entities.ContainsKeyAlt(entity))
							return false;
					return true;
				case Notation(let list):
					for (let item in list)
						if (self.notations.ContainsKey(item))
							return true;
					return false;
				}
			}

			public override void ToString(String strBuffer)
			{
				switch (this)
				{
				case .CData: strBuffer.Append("CDATA");
				case .Id: strBuffer.Append("ID");
				case .IdRef: strBuffer.Append("IDREF");
				case .IdRefs: strBuffer.Append("IDREFS");
				case .NmToken: strBuffer.Append("NMTOKEN");
				case .NmTokens: strBuffer.Append("NMTOKENS");
				case .Entity: strBuffer.Append("ENTITY");
				case .Entities: strBuffer.Append("ENTITIES");
				case .OneOf(let p0):
					strBuffer.Append("(");
					for (let item in p0)
					{
						strBuffer.Append(item);
						if (@item.Index + 1 < p0.Count)
							strBuffer.Append('|');
					}
					strBuffer.Append(")");
				case .Notation(let p0):
					strBuffer.Append("NOTATION ");
					Self.OneOf(p0).ToString(strBuffer);
				}
			}
		}

		public enum AttributeDefaultValue
		{
			case Required, Implied;
			case Value(String), Fixed(String);

			public static Result<Self> Parse(MarkupSource source, Doctype self, AttributeType type, XmlVersion version)
			{
				if (source.Consume("#REQUIRED"))
					return .Ok(.Required);
				if (source.Consume("#IMPLIED"))
					return .Ok(.Implied);
				bool isFixed = source.Consume("#FIXED");

				String value = new:(self.alloc) .(8);
				if (!source.Consume('"'))
				{
					source.Error("Expected attribute value");
					return .Err;
				}
				char32 c;
				while (true)
				{
					if (!source.PeekNext(out c, let length)) break;
					source.MoveBy(length);
					if (c.IsWhiteSpace || c == '"') break;
					value.Append(c);
				}

				if (!type.Matches(value, self.IDs, self.IDREFs, self, version))
				{
					source.Error("Default value does not match attribute type");
					return .Err;
				}

				if (isFixed)
					return .Ok(.Fixed(value));
				else
					return .Ok(.Value(value));
			}

			public override void ToString(String strBuffer)
			{
				switch (this)
				{
				case .Fixed(let value): strBuffer.AppendF($"#FIXED \"{value}\"");
				case .Value(let value): strBuffer.AppendF($"\"{value}\"");
				case .Implied: strBuffer.Append("#IMPLIED");
				case .Required: strBuffer.Append("#REQUIRED");
				}
			}
		}

		public static Result<Self> Parse(MarkupSource source, Doctype self, XmlVersion version)
		{
			Self output = ?;
			output.type = Try!(AttributeType.Parse(source, self.alloc, version));
			if (!source.ConsumeWhitespace())
			{
				source.Error("Expected attribute type");
				return .Err;
			}
			output.value = Try!(AttributeDefaultValue.Parse(source, self, output.type, version));
			return output;
		}
	}

	public struct Element : this(ElementContents contents, Dictionary<String, Attlist> attlists);
	public struct Entity : this(MarkupUri uri, bool parse, String notation)
	{
		public Result<void> GetRawData(String strBuffer, MarkupSource source)
		{
			if (uri case .Raw(let raw))
			{
				strBuffer.Append(raw);
				return .Ok;
			}

			let stream = Try!(uri.Open(source));
			if (stream.ReadStrC(strBuffer) case .Err) { /* We pass because files don't have to end with \0 */ }
			stream.Close(); delete stream;
			return .Ok;
		}
	}

	public Dictionary<String, Element> elements = new:alloc .(16);
	public Dictionary<String, Entity> entities = new:alloc .(6);
	public Dictionary<String, MarkupUri> notations = new:alloc .();

	HashSet<String> IDs = new:alloc .(6), IDREFs = new:alloc .(6);

	public static Result<Self> Parse(MarkupSource source, BumpAllocator allocTo = null, bool inlined = false, XmlVersion version = .V1_0)
	{
		Self self = allocTo == null ? new .() : new:allocTo .();
		HashSet<String> referencedNotations = scope .();

		Result<String> NextWord(StringView name, bool quote = false)
		{
			char8 quoteChar = ?;
			do
			{
				if (quote && source.Consume('"')) { quoteChar = '"'; break; }
				if (quote && source.Consume('\'')) { quoteChar = '\''; break; }
				if (!quote && (source.ConsumeWhitespace() || name.IsNull) && !source.Consume('>')) break;
				if (!name.IsNull) source.Error($"Expected {name}");
				return .Err;
			}
			String builder = new:(self.alloc) .(8);
			char32 c;
			while (true)
			{
				if (!source.PeekNext(out c, let length) || (!quote && c.IsWhiteSpace))
					break;
				source.MoveBy(length);
				if (c == '>' && !quote)
				{
					source.Error("Unexpected '>'");
					return .Err;
				}
				if (c == quoteChar && quote) break;
				if (quote)
					Util.EnsureChar!(c, version, source);
				else
					Util.EnsureNmToken!(c, version, source);
				builder.Append(c);
			}
			if (!builder.IsEmpty) return builder;
			if (!name.IsNull) source.Error($"Expected {name}");
			return .Err;
		}

		mixin Close()
		{
			if (!source.Consume('>'))
			{
				source.Error("Expected '>'");
				return .Err;
			}
			continue;
		}

		while (true)
		{
			source.ConsumeWhitespace();
			if (source.Ended) break;

			if (inlined && source.Consume(']')) break;
			if (!source.Consume("<", "!"))
			{
				source.Error("Expected '<!'");
				return .Err;
			}

			if (source.Consume("ATTLIST"))
			{
				let name = Try!(NextWord("element name"));
				Element* valuePtr;
				switch (self.elements.TryAdd(name))
				{
				case .Added(?, out valuePtr):
					*valuePtr = .(.Open, new:(self.alloc) .(2));
				case .Exists(?, out valuePtr):
				}

				let key = Try!(NextWord("attribute name"));
				if (valuePtr.attlists.ContainsKey(key))
				{
					source.Error($"Attribute {key} of element {name} is already defined");
					return .Err;
				}
				valuePtr.attlists.Add(key, Try!(Attlist.Parse(source, self, version)));
				Close!();
			}

			if (source.Consume("ELEMENT"))
			{
				let name = Try!(NextWord("element name"));
				Element* valuePtr;
				switch (self.elements.TryAdd(name))
				{
				case .Added(?, out valuePtr):
					valuePtr.attlists = new:(self.alloc) .();
				case .Exists(?, out valuePtr):
					if (valuePtr.contents case .Open) break;
					source.Error($"Element {name} is already defined");
					return .Err;
				}

				valuePtr.contents = Try!(ElementContents.Parse(source, self.alloc, version));
				Close!();
			}

			if (source.Consume("ENTITY"))
			{
				let name = Try!(NextWord("entity name"));
				let value = Try!(MarkupUri.Parse(source, self.alloc, true));
				bool parseable = !(value case .Raw);
				String notation = null;
				if (!parseable) do
				{
					if (!source.Consume("NDATA")) break;
					notation = Try!(NextWord("notation"));
					referencedNotations.Add(notation);
					parseable = false;
				}
				if (self.entities.TryAdd(name, .(value, parseable, notation)))
					Close!();
				source.Error($"Entity {name} was already defined");
				return .Err;
			}

			if (source.Consume("NOTATION"))
			{
				let name = Try!(NextWord("notation name"));
				if (self.notations.TryAdd(name, Try!(MarkupUri.Parse(source, self.alloc))))
					Close!();
				source.Error($"Duplicate notation {name}");
				return .Err;
			}

			if (source.Consume("--"))
			{
				while (!source.Consume("--", ">"))
					source.MoveBy(1);
				continue;
			}

			switch (NextWord(null))
			{
			case .Err:
				source.Error($"Unexpected '{source.PeekNext(..?, ?)}'");
			case .Ok(let val):
				source.Error($"Unexpected '{val}'");
			}
			return .Err;
		}

		for (let element in self.elements)
		{
			if (!(element.value.contents case .Open)) continue;
			source.Error($"Element {element.key} was referenced but never defined");
			return .Err;
		}

		for (let notation in referencedNotations)
		{
			if (self.notations.ContainsKey(notation)) continue;
			source.Error($"Notation {notation} was referenced but never defined");
			return .Err;
		}

		return self;
	}
}