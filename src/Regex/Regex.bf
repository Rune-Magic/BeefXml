using System;
using System.Collections;
using System.Diagnostics;

namespace Regex;

static class Regex
{
	public enum RegexParseError
	{
		case Unexpected(char8);
		case UnrecognisedEscapeSequence(char8);
		case GroupNotClosed;
	}

	public static Result<RegexTreeNode, RegexParseError> Parse(StringView string, IRawAllocator alloc)
	{
		Queue<RegexTreeNode> depth = scope .(4);

		mixin Assert(bool condition, RegexParseError error)
		{
			if (!condition)
				return .Err(error);
		}

		void Insert(RegexTreeNode node)
		{
			if (depth.IsEmpty)
				depth.Add(new:alloc RegexSequence() { children = new:alloc .(4) { node } });
			else if (let sequence = depth.Back as RegexSequence)
				sequence.children.Add(node);
			else if (let enumeration = depth.Back as RegexEnumeration)
				enumeration.options.Add(node);
			else Internal.FatalError(scope $"{depth.Back} not handled");
		}

		bool escaped = false;
		Result<void, RegexParseError> Parse(Span<char8>.Enumerator iter)
		{
			let c = iter.Current;

			if (escaped)
			{
				escaped = false;

				switch (c)
				{
				case '[', '\\', '^', '$', '.', '|', '?', '*', '+', '(', ')', '{', '}':
					Insert(new:alloc RegexCharacterNode() { char = c });
				case 'A':
					Insert(new:alloc RegexAnchorNode() { type = .StartString });
				case 'Z':
					Insert(new:alloc RegexAnchorNode() { type = .EndString });
				case 'b':
					Insert(new:alloc RegexAnchorNode() { type = .WordBoundary });
				case 'B':
					Insert(new:alloc RegexAnchorNode() { type = .NoWordBoundary });
				case '<':
					Insert(new:alloc RegexAnchorNode() { type = .WordStart });
				case '>':
					Insert(new:alloc RegexAnchorNode() { type = .WordEnd });
				default:
					return .Err(.UnrecognisedEscapeSequence(c));
				}

				return .Ok;
			}
		}

		for (char8 c in string)
		{
			Try!(Parse(@c));
		}

		Debug.Assert(!depth.IsEmpty);
		Assert!(depth.Count == 1, RegexParseError.GroupNotClosed);
		return depth.Front;
	}
}