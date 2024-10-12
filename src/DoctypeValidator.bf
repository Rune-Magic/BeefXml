using System;
using System.Collections;

namespace Xml;

class DoctypeValidator : XmlInsertVisitor, this()
{
	public override Options Flags => .VisitEOF;

	HashSet<String> IDs = new .() ~ delete _;
	HashSet<String> IDREFs = new .() ~ delete _;

	Doctype Doctype => Pipeline.CurrentHeader.doctype;

	Doctype.Element* current = null;
	String currentName = null;
	Queue<HashSet<String>> encountered = new .(16) ~ DeleteContainerAndItems!(_);
	Queue<HashSet<List<Doctype.ElementContents>>> encounteredFurry = new .(16) ~ DeleteContainerAndItems!(_);
	HashSet<String> attributes = new .(8) ~ delete _;
	bool pcdata = false;
	bool cdata = false;
	bool root = true;
	public override Action Visit(ref XmlVisitable node)
	{
		if (Doctype == null) return .Continue;

		mixin Try(var result)
		{
			if (result case .Err)
				return .Error;
			result.Get()
		}

		Result<void> SetCurrent()
		{
			currentName = TagDepth.Back;
			if (!Doctype.elements.TryGetRef(currentName, ?, let value))
			{
				Pipeline.CurrentReader.Error($"Element {currentName} not found in doctype");
				return .Err;
			}
			current = value;
			pcdata = false;
			cdata = false;
			switch (value.contents)
			{
			case .PCData: pcdata = true;
			case .CData: cdata = true;
			case .Any:
				pcdata = true;
				cdata = true;
			case .AllOf(var list), .AnyOf(out list):
				for (let child in list)
					switch (child)
					{
					case .PCData: pcdata = true;
					case .CData: cdata = true;
					default:
					}
			default:
			}
			return .Ok;
		}

		[Inline]
		Result<void> Ensure(bool condition, StringView errorMsg, params Object[] args)
		{
			if (!condition)
			{
				Pipeline.CurrentReader.Error(errorMsg, params args);
				return .Err;
			}
			return .Ok;
		}

		switch (node)
		{
		case .Err: return .Error;
		case .OpeningTag(let name):
			if (root)
			{
				root = false;
				Try!(Ensure(Pipeline.CurrentHeader.rootNode == name, $"Root tag has to be called {Pipeline.CurrentHeader.rootNode} not {name}"));
				encountered.Add(new .(8));
				encounteredFurry.Add(new .());
				SetCurrent();
				break;
			}

			Try!(Ensure(!(current.contents case .Empty), $"Element {currentName} has to be empty"));

			if (!Doctype.elements.ContainsKey(name))
			{
				if (pcdata) break;
				Pipeline.CurrentReader.Error($"Element {name} not found in doctype");
				return .Error;
			}

			if (!(current.contents case .Any))
			{
				bool Validate(Doctype.ElementContents contents, bool allowDuplicates = false)
				{
					switch (contents)
					{
					case .Empty, .Any, .Open:
						Internal.FatalError(.ConstF($"code broken ({nameof(Self)})"));
					case .PCData:
						return true;
					case .CData:
						return false;
					case .Child(let child):
						if (child != name) return false;
						if (!allowDuplicates && encountered.Back.Contains(child))
							return false;
						return true;
					case .Optional(let element):
						return Validate(*element);
					case .OneOrMore(var element), .ZeroOrMore(out element):
						return Validate(*element, true);
					case .AllOf(let children):
						for (let child in children)
							if (Validate(child, allowDuplicates))
								return true;
						return false;
					case .AnyOf(let children):
						if (encounteredFurry.Back.Contains(children))
							return false;
						for (let child in children)
						{
							if (!Validate(child, allowDuplicates)) continue;
							encounteredFurry.Back.Add(children);
							return true;
						}
						return false;
					}
				}

				Try!(Ensure(Validate(current.contents), $"Element {name} is not valid here"));
			}

			encountered.Back.Add(name);
			encountered.Add(new .(8));
			encounteredFurry.Add(new .());
			SetCurrent();
		case .CharacterData:
			Try!(Ensure(cdata, "CDATA is not valid here"));
		case .Attribute(let key, let value):
			Try!(Ensure(current.attlists.TryGet(key, ?, let match), $"Attribute {key} not found in doctype"));
			Try!(Ensure(match.type.Matches(value, IDs, IDREFs, Doctype, Pipeline.CurrentHeader.version), $"Attribute value \"{value}\" is not valid here"));
			Try!(Ensure(attributes.Add(key), $"Duplicate attribute {key}"));
		case .EOF:
			root = true;
			for (let idref in IDREFs)
				Try!(Ensure(IDs.Contains(idref), $"ID {idref} was referenced but never defined"));
		case .OpeningEnd(let bodyless):
			for (let attr in current.attlists)
			{
				if (attributes.Contains(attr.key)) continue;
				switch (attr.value.value)
				{
				case .Required:
					CurrentSource.Error($"Required attribute {attr.key} missing");
					return .Error;
				case .Implied:
					continue;
				case .Fixed(var value), .Value(out value):
					InsertBeforeCurrent(.Attribute(attr.key, value));
				}
			}

			if (bodyless)
				fallthrough;
		case .ClosingTag:
			let elements = encountered.PopBack(); defer delete elements;
			let elementsFurry = encounteredFurry.PopBack(); defer delete elementsFurry;

			bool Validate(Doctype.ElementContents contents)
			{
				switch (contents)
				{
				case .Child(let name):
					return Ensure(elements.Contains(name), $"Missing element {name} from {currentName}") case .Ok;
				case .AnyOf(let children):
					return Ensure(elementsFurry.Contains(children), $"One of {contents} must be present in {currentName}") case .Ok;
				case .AllOf(let children):
					for (let child in children)
						if (!Validate(child))
						{
							Pipeline.CurrentReader.Error($"All of {contents} must be present in {currentName}");
							return false;
						}
					return true;
				case .OneOrMore(let element):
					return Validate(*element);
				default:
					return true;
				}
			}

			if (!Validate(current.contents)) return .Error;
			if (TagDepth.IsEmpty) break;
			SetCurrent();
		}
		return .Continue;
	}
}