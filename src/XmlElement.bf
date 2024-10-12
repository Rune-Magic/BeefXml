using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Xml;

/// represents a parsed xml element
class XmlElement
{
	/// the text before the element, may be null
	public String PrecedingText = null;
	/// the last text block in the element, may be null
	public String FooterText = null;
	public List<XmlElement> Children = null;
	public Dictionary<String, String> Attributes = null;
	public String Name = null;

	/// this class is a visitor so put it into a pipeline to initialize it
	/// NOTE: the element's life time matches the XmlReader's lifetime
	public class Builder : XmlVisitor, IResultVisitor<XmlElement>
	{
		public override Options Flags => .None;
		public XmlElement Result { get; set; } = null;

		private List<XmlElement> currentStack = null;
		private XmlElement Current => currentStack.Back;
		private String lastCdata = null;
		public override Action Visit(ref XmlVisitable node)
		{
			if (currentStack == null)
				currentStack = new .(5);

			switch (node)
			{
			case .OpeningTag(let name):
				XmlElement next = new:(Pipeline.CurrentReader.[Friend]alloc) .() {
					Children = new:(Pipeline.CurrentReader.[Friend]alloc) .(),
					Attributes = new:(Pipeline.CurrentReader.[Friend]alloc) .(),
					Name = name,
					PrecedingText = lastCdata,
				};
				if (!currentStack.IsEmpty)
					Current.Children.Add(next);
				lastCdata = null;
				currentStack.Add(next);
			case .OpeningEnd(let singleton):
				if (singleton) fallthrough;
			case .ClosingTag:
				Current.FooterText = lastCdata;
				lastCdata = null;
				Result = currentStack.PopBack();
				if (currentStack.IsEmpty)
				{
					DeleteAndNullify!(currentStack);
					return .Terminate;
				}
			case .Attribute(let key, let value):
				Current.Attributes.Add(key, value);
			case .CharacterData(let data):
				lastCdata = data;
			case .Err, .EOF:
				Internal.FatalError(.Empty);
			}

			return .Continue;
		}

	}
}