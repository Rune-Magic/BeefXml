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
		case Empty, Any, PCData;
		case Child(String name);
		case Optional(ElementContents* element);
		case OneOrMore(ElementContents* element);
		case ZeroOrMore(ElementContents* element);

		public static Result<Self> Parse(SourceProvider sourceProvider, BumpAllocator alloc, XmlVersion version, Doctype self, bool root = true)
		{
			self.EntityOverride(version);
			defer
			{
				mixin Package(ElementContents c)
				{
					ElementContents *ptr = new:alloc .();
					*ptr = c;
					ptr
				}

				if (!(@return case .Err))
				{
					if (sourceProvider.Source.Consume('?'))
						@return = .Ok(.Optional(Package!(@return.Value)));
					else if (sourceProvider.Source.Consume('+'))
						@return = .Ok(.OneOrMore(Package!(@return.Value)));
					else if (sourceProvider.Source.Consume('*'))
						@return = .Ok(.ZeroOrMore(Package!(@return.Value)));
				}
			}

			if (sourceProvider.Source.Consume('('))
			{
				const int8 Type_None = 0;
				const int8 Type_Or = 1;
				const int8 Type_And = 2;

				int8 type = Type_None;
				List<ElementContents> output = new:alloc .();

				bool pcdata = false;
				while (true)
				{
					output.Add(Try!(Parse(sourceProvider, alloc, version, self, false)));
					switch (output.Back)
					{
					case .PCData:
						if (pcdata)
						{
							sourceProvider.Source.Error("Duplicate #PCDATA");
							return .Err;
						}
						pcdata = true;
					when pcdata && type == Type_And:
						sourceProvider.Source.Error("Cannot mix #PCDATA and other content");
						return .Err;
					default:
					}
					if (sourceProvider.Source.Consume(')')) break;
					if (sourceProvider.Source.Consume('|'))
					{
						if (type == Type_And)
						{
							sourceProvider.Source.Error("Unexpected '|'");
							return .Err;
						}
						type = Type_Or;
						continue;
					}
					if (sourceProvider.Source.Consume(','))
					{
						if (type == Type_Or)
						{
							sourceProvider.Source.Error("Unexpected ','");
							return .Err;
						}
						type = Type_And;
						continue;
					}

					sourceProvider.Source.Error($"Unexpected '{sourceProvider.Source.PeekNext(..?, ?)}'");
					return .Err;
				}

				switch (type)
				{
				case Type_None:
					if (output.IsEmpty)
					{
						sourceProvider.Source.Error(new:alloc $"Expected element content");
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
				if (sourceProvider.Source.Consume("EMPTY"))
					return .Ok(.Empty);
				if (sourceProvider.Source.Consume("ANY"))
					return .Ok(.Any);
				sourceProvider.Source.Error("Expected '(', 'ANY' or 'EMPTY'");
				return .Err;
			}

			if (sourceProvider.Source.Consume("#PCDATA"))
				return .Ok(.PCData);

			char32 c;
			bool firstChar = true;
			String name = new:alloc .(16);
			while (true)
			{
				if (!sourceProvider.Source.PeekNext(out c, let length)) break;
				if (c.IsWhiteSpace || (length == 1 && ",?+<>|()'\"".Contains((char8)c))) break;
				Util.EnsureNmToken!(c, version, sourceProvider.Source, firstChar);
				firstChar = false;
				name.Append(c);
				sourceProvider.Source.MoveBy(length);
			}

			return .Ok(.Child(name));
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

			public static Result<Self> Parse(SourceProvider sourceProvider, BumpAllocator alloc, XmlVersion version)
			{
				bool notation = sourceProvider.Source.Consume("NOTATION");
				if (sourceProvider.Source.Consume('('))
				{
					List<String> options = new:alloc .(8) { new:alloc .(8) };
					char32 c;
					bool firstChar = true;
					while (true)
					{
						if (!sourceProvider.Source.PeekNext(out c, let length))
						{
							sourceProvider.Source.Error("Expected ')'");
							return .Err;
						}
						sourceProvider.Source.MoveBy(length);
						if (c == '|')
						{
							options.Back.Trim();
							options.Add(new:alloc .(8));
							continue;
						}
						if (c == ')') break;
						if (notation && c.IsWhiteSpace)
						{
							if (sourceProvider.Source.Consume('|'))
							{
								options.Back.TrimStart();
								options.Add(new:alloc .(8));
								continue;
							}
							sourceProvider.Source.Error("Expected notation");
							return .Err;
						}
						Util.EnsureNmToken!(c, version, sourceProvider.Source, firstChar);
						firstChar = false;
						options.Back.Append(c);
					}
					if (notation)
						return .Ok(.Notation(options));
					return .Ok(.OneOf(options));
				}

				if (sourceProvider.Source.Consume("ENTITIES"))
					return .Ok(.Entities);
				if (sourceProvider.Source.Consume("ENTITY"))
					return .Ok(.Entity);
				if (sourceProvider.Source.Consume("CDATA"))
					return .Ok(.CData);
				if (sourceProvider.Source.Consume("NMTOKENS"))
					return .Ok(.NmToken);
				if (sourceProvider.Source.Consume("NMTOKEN"))
					return .Ok(.NmTokens);
				if (sourceProvider.Source.Consume("IDREFS"))
					return .Ok(.IdRefs);
				if (sourceProvider.Source.Consume("IDREF"))
					return .Ok(.IdRef);
				if (sourceProvider.Source.Consume("ID"))
					return .Ok(.Id);

				sourceProvider.Source.Error("Expected attribute type");
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

			public static Result<Self> Parse(SourceProvider sourceProvider, Doctype self, AttributeType type, XmlVersion version)
			{
				self.EntityOverride(version);
				if (sourceProvider.Source.Consume("#REQUIRED"))
					return .Ok(.Required);
				if (sourceProvider.Source.Consume("#IMPLIED"))
					return .Ok(.Implied);
				bool isFixed = sourceProvider.Source.Consume("#FIXED");

				String value = new:(self.alloc) .(8);
				if (!sourceProvider.Source.Consume('"'))
				{
					sourceProvider.Source.Error("Expected attribute value");
					return .Err;
				}
				char32 c;
				while (true)
				{
					if (!sourceProvider.Source.PeekNext(out c, let length)) break;
					sourceProvider.Source.MoveBy(length);
					if (c.IsWhiteSpace || c == '"') break;
					value.Append(c);
				}

				if (!type.Matches(value, self.IDs, self.IDREFs, self, version))
				{
					sourceProvider.Source.Error("Default value does not match attribute type");
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

		public static Result<Self> Parse(SourceProvider sourceProvider, Doctype self, XmlVersion version)
		{
			Self output = ?;
			self.EntityOverride(version);
			output.type = Try!(AttributeType.Parse(sourceProvider, self.alloc, version));
			if (!sourceProvider.Source.ConsumeWhitespace())
			{
				sourceProvider.Source.Error("Expected attribute type");
				return .Err;
			}
			output.value = Try!(AttributeDefaultValue.Parse(sourceProvider, self, output.type, version));
			return output;
		}
	}

	public enum EntityContents
	{
		case Parsed(MarkupUri uri), Notation(String notation, MarkupUri uri), General(String data);

		public Result<void> GetRawData(String strBuffer, MarkupSource source)
		{
			switch (this)
			{
			case .General(let data):
				strBuffer.Append(data);
				return .Ok;
			case .Parsed(var uri), .Notation(?, out uri):
				let stream = Try!(uri.Open(source));
				if (stream.ReadStrC(strBuffer) case .Err) { /* We pass because files don't have to end with \0 */ }
				stream.Close(); delete stream;
				return .Ok;
			}
		}
	}

	public struct Entity : this(EntityContents contents, bool parameter, MarkupSource.Index startIndex);
	public struct Element : this(ElementContents contents, Dictionary<String, Attlist> attlists);

	public Dictionary<String, Element> elements = new:alloc .(16);
	public Dictionary<String, Entity> entities = new:alloc .(6);
	public Dictionary<String, MarkupUri> notations = new:alloc .();

	HashSet<String> IDs = new:alloc .(6), IDREFs = new:alloc .(6);

	private static SourceProvider sourceProvider = new .() ~ delete _;
	private static MarkupSource Source
	{
		[Inline] get => sourceProvider.Source;
		[Inline] set => sourceProvider.Source = value;
	}

	Result<bool> EntityOverride(XmlVersion version)
	{
		char8 entityChar;
		if (Source.Consume('%')) entityChar = '%';
		else if (Source.Consume('&')) entityChar = '&';
		else return false;
		if (Source.Consume('%'))
		{
			Source.Error("Expected entity name");
			return .Err;
		}

		bool firstChar= true;
		String name = scope .(8);
		while (true)
		{
			if (!Source.PeekNext(let c, let length))
			{
				Source.Error("Expected ';'");
				return .Err;
			}
			Source.MoveBy(length);
			if (c == ';') break;
			Util.EnsureNmToken!(c, version, Source, firstChar);
			firstChar = false;
			name.Append(c);
		}

		for (let entity in entities)
		{
			if (name != entity.key) continue;
			switch (entity.value.contents)
			{
			case .Parsed(var uri), .Notation(?, out uri):
				Try!(sourceProvider.OpenSource(uri));
			case .General(let data):
				Source = new .(new .(new StringStream(data, .Copy)), entity.key);
			}
			return true;
		}

		Source.Error($"Entity '{name}' doesn't exist");
		return .Err;
	}

	public static Result<Self> Parse(MarkupSource source, BumpAllocator allocTo = null, bool inlined = false, XmlVersion version = .V1_0)
	{
		Self self = allocTo == null ? new .() : new:allocTo .();
		HashSet<String> referencedNotations = scope .();
		sourceProvider.DefaultSource = source;

		mixin Consume(StringView str)
		{
			Try!(self.EntityOverride(version));
			Source.Consume(str)
		}

		mixin Consume(StringView str1, StringView str2)
		{
			Try!(self.EntityOverride(version));
			Source.Consume(str1, str2)
		}

		mixin Consume(StringView str1, StringView str2, StringView str3)
		{
			Try!(self.EntityOverride(version));
			Source.Consume(str1, str2, str3)
		}

		mixin Consume(char8 c)
		{
			Try!(self.EntityOverride(version));
			Source.Consume(c)
		}

		Result<String> NextWord(StringView name, bool quote = false)
		{
			char8 quoteChar = ?;
			do
			{
				if (quote && Source.Consume('"')) { quoteChar = '"'; break; }
				if (quote && Source.Consume('\'')) { quoteChar = '\''; break; }
				if (!Source.Consume('>')) break;
				if (!name.IsNull) Source.Error($"Expected {name}");
				return .Err;
			}
			String builder = new:(self.alloc) .(16);
			char32 c;
			bool firstChar = true;
			while (true)
			{
				if (!Source.PeekNext(out c, let length) || (!quote && c.IsWhiteSpace))
					break;
				Source.MoveBy(length);
				if (c == '>' && !quote)
				{
					Source.Error("Unexpected '>'");
					return .Err;
				}
				if (c == quoteChar && quote) break;
				if (quote)
					Util.EnsureChar!(c, version, Source);
				else
					Util.EnsureNmToken!(c, version, Source, firstChar);
				firstChar = false;
				builder.Append(c);
			}
			if (!builder.IsEmpty) return builder;
			if (!name.IsNull) Source.Error($"Expected {name}");
			return .Err;
		}

		mixin Close()
		{
			if (!Consume!('>'))
			{
				Source.Error("Expected '>'");
				return .Err;
			}
			continue loop;
		}

		loop: while (true)
		{
			Source.ConsumeWhitespace();
			if (Source.Ended && !sourceProvider.PopSource()) break;
			if (inlined && sourceProvider.SourceOverride.IsEmpty && Consume!(']')) break;

			if (!Consume!("<", "!"))
			{
				Source.Error("Expected '<!'");
				return .Err;
			}

			if (Consume!("ATTLIST"))
			{
				let name = Try!(NextWord("element name"));
				while (true)
				{
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
						Source.Error($"Attribute {key} of element {name} is already defined");
						return .Err;
					}
					valuePtr.attlists.Add(key, Try!(Attlist.Parse(sourceProvider, self, version)));
					if (Consume!(">", ""))
						continue loop;
				}
			}

			if (Consume!("ELEMENT"))
			{
				let name = Try!(NextWord("element name"));
				Element* valuePtr;
				switch (self.elements.TryAdd(name))
				{
				case .Added(?, out valuePtr):
					valuePtr.attlists = new:(self.alloc) .();
				case .Exists(?, out valuePtr):
					if (valuePtr.contents case .Open) break;
					Source.Error($"Element {name} is already defined");
					return .Err;
				}

				valuePtr.contents = Try!(ElementContents.Parse(sourceProvider, self.alloc, version, self));
				Close!();
			}

			if (Consume!("ENTITY"))
			{
				bool parameter = Source.Consume('%');
				let name = Try!(NextWord("entity name"));
				let uriIndex = Source.CurrentIdx;
				let uri = Try!(MarkupUri.Parse(Source, self.alloc, true));
				bool parseable = !(uri case .Raw);
				String notation = null;
				if (!parseable) do
				{
					if (!Consume!("NDATA")) break;
					notation = Try!(NextWord("notation"));
					referencedNotations.Add(notation);
					parseable = false;
				}
				EntityContents contnets;
				if (uri case .Raw(let raw))
					contnets = .General(raw);
				else if (parseable)
					contnets = .Parsed(uri);
				else
					contnets = .Notation(notation, uri);
				if (self.entities.TryAdd(name, .(contnets, parameter, uriIndex)))
					Close!();
				Source.Error($"Entity {name} was already defined");
				return .Err;
			}

			if (Consume!("NOTATION"))
			{
				let name = Try!(NextWord("notation name"));
				if (self.notations.TryAdd(name, Try!(MarkupUri.Parse(Source, self.alloc))))
					Close!();
				Source.Error($"Duplicate notation {name}");
				return .Err;
			}

			if (Consume!("--"))
			{
				while (!Consume!("--", ">"))
					Source.MoveBy(1);
				continue;
			}

			switch (NextWord(null))
			{
			case .Err:
				Source.Error($"Unexpected '{Source.PeekNext(..?, ?)}'");
			case .Ok(let val):
				Source.Error($"Unexpected '{val}'");
			}
			return .Err;
		}

		for (let element in self.elements)
		{
			if (!(element.value.contents case .Open)) continue;
			Source.Error($"Element {element.key} was referenced but never defined");
			return .Err;
		}

		for (let notation in referencedNotations)
		{
			if (self.notations.ContainsKey(notation)) continue;
			Source.Error($"Notation {notation} was referenced but never defined");
			return .Err;
		}

		return self;
	}
}