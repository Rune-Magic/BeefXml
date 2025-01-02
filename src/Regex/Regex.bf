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
		case GroupNotClosed(char8);
		case UnexpectedQuantifier(char8);
		case InvalidChar(char8);
		case UnexpectedEndOfString;

		public static explicit operator Self(void v) => .UnexpectedEndOfString;
	}

	public static Result<RegexTreeNode, (RegexParseError error, int index)> Parse(StringView string, BumpAllocator alloc)
	{
		Runtime.NotImplemented();
		Queue<RegexTreeNode> depth = scope .(4);

		bool CloseEnum()
		{
			let entry = depth.PopBack();
			let options = depth.Front as RegexEnumeration;
			if (options == null)
			{
				depth.Add(entry);
				return false;
			}
			options.options.Add(entry);
			return true;
		}

		RegexTreeNode Tail()
		{
			Debug.Assert(!depth.IsEmpty);
			if (let sequence = depth.Back as RegexSequence)
				return sequence.children.Back;
			else if (let enumeration = depth.Back as RegexEnumeration)
				return enumeration.options.Back;
			else
				return depth.Back;
		}

		Result<void, RegexParseError> Parse(ref Span<char8>.Enumerator iter, Queue<char8> nesting)
		{
			var c = Try!(iter.GetNext());

			Result<void, RegexParseError> Insert(RegexTreeNode node)
			{
				quantify: do switch (iter.GetNext())
				{
				case .Ok(let val):
					if (let q = node as RegexQuantifier)
					{
						if (val == '?')
							switch (Parse(ref iter, nesting))
							{
							case .Ok:
								q.lazyStop = Tail();
								break quantify;
							case .Err:
							}
					}
					else switch (val)
					{
					case '?':
						Try!(Insert(new:alloc RegexQuantifier() { type = .Optional, child = node }));
						return .Ok;
					case '+':
						Try!(Insert(new:alloc RegexQuantifier() { type = .OneOrMore, child = node }));
						return .Ok;
					case '*':
						Try!(Insert(new:alloc RegexQuantifier() { type = .ZeroOrMore, child = node }));
						return .Ok;
					case '{':
						int? first = null;
 						int? second = null;
						int index = 0;
						String buffer = scope .(8);
						bool breakLoop = false;
						loop: while (true) switch (iter.GetNext())
						{
						case .Ok(let char):
							ok: do
							{
								switch (char)
								{
								case '}':
									breakLoop = true;
									fallthrough;
								case ',':
									index++;
								when char.IsDigit:
									buffer.Append(char);
									break ok;
								default:
									return .Err(.Unexpected(char));
								}

								if (!buffer.IsEmpty)
								{
									switch (index)
									{
									case 1: first = int.Parse(buffer);
									case 2: second = int.Parse(buffer);
									default:
										return .Err(.Unexpected(','));
									}
									buffer.Clear();
								}
								//else if (breakLoop) return .Err(.Unexpected('}'));
								if (breakLoop) break loop;
							}
						case .Err:
							return .Err(.UnexpectedEndOfString);
						}
						RegexQuantifier.Type type;
						switch (index)
						{
						case 1:
							type = .Exact((.)first);
						case 2:
							if (first == null && second != null)
								type = .Until((.)second);
							else if (first != null && second == null)
								type = .AtLeast((.)first);
							else if (first != null && second != null)
								type = .Range((.)first...(.)second);
							else return .Err(.Unexpected('}'));
						default:
							return .Err(.Unexpected(','));
						}
						Try!(Insert(new:alloc RegexQuantifier() { type = type, child = node }));
						return .Ok;
					}
					iter.[Friend]mIndex--;
				case .Err:
				}

				if (depth.IsEmpty)
					depth.Add(new:alloc RegexSequence() { children = new:alloc .(4) { node } });
				else if (let sequence = depth.Back as RegexSequence)
					sequence.children.Add(node);
				else if (let enumeration = depth.Back as RegexEnumeration)
					enumeration.options.Add(node);
				else Internal.FatalError(scope $"{depth.Back} not handled");

				return .Ok;
			}

			if (c == '\\')
			{
				c = Try!(iter.GetNext());
				switch (c)
				{
				case '[', '\\', '^', '$', '.', '|', '?', '*', '+', '(', ')', '{', '}', '/', '-':
					Try!(Insert(new:alloc RegexCharacterNode() { char = c }));

				case 'A':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .StartString }));
				case 'Z':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .EndString }));
				case 'b':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .WordBoundary }));
				case 'B':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .NoWordBoundary }));
				case '<':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .WordStart }));
				case '>':
					Try!(Insert(new:alloc RegexAnchorNode() { type = .WordEnd }));

				case 'd':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .Digit }));
				case 'x':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .HexDigit }));
				case 'O':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .OctalDigit }));
				case 'w':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .WordCharacter }));
				case 'n':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NewLine }));
				case 'W':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NotWordCharacter }));
				case 'N':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NotNewLine }));
				case 'D':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NotDigit }));
				case 'i':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .XmlNmTokenStartChar }));
				case 'c':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .XmlNmTokenChar }));
				case 'I':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NotXmlNmTokenStartChar }));
				case 'C':
					Try!(Insert(new:alloc RegexPredefinedNode() { type = .NotXmlNmTokenChar }));

				default:
					return .Err(.UnrecognisedEscapeSequence(c));
				}

				return .Ok;
			}

			switch (c)
			{
			case '(':
				RegexSequence seq = new:alloc .() { children = new:alloc .(4) };
				depth.Add(seq);
				nesting.Add(')');
				c = Try!(iter.GetNext());
				if (c != '?') iter.[Friend]mIndex--;
				c = Try!(iter.GetNext());
				if (c != '<')
				{
					iter.[Friend]mIndex--;
					return .Err(.Unexpected('?'));
				}
				seq.name = new:alloc .(8);
				while (true)
				{
					c = Try!(iter.GetNext());
					if (c == '>') break;
					if ((!c.IsLetterOrDigit && c != '_') || (c.IsDigit && seq.name.IsEmpty))
						return .Err(.InvalidChar(c));
					seq.name.Append(c);
				}
			case '[':
				c = Try!(iter.GetNext());
				if (c != '^') iter.[Friend]mIndex--;
				depth.Add(new:alloc RegexEnumeration() { options = new:alloc .(3), negitive = c == '^' });
				nesting.Add(']');
			case '|':
				if (!nesting.IsEmpty && nesting.Back == ']')
					return .Err(.Unexpected('|'));
				let entry = depth.PopBack();
				if (let options = depth.Back as RegexEnumeration)
				{
					options.options.Add(entry);
					return .Ok;
				}
				depth.Add(new:alloc RegexEnumeration() { options = new:alloc .(3) { entry } });
				depth.Add(new:alloc RegexSequence() { children = new:alloc .(4) });
			case '+', '*', '{', '?':
				return .Err(.UnexpectedQuantifier(_));
			when !nesting.IsEmpty && _ == nesting.Back:
				if (CloseEnum()) return .Ok;
				Try!(Insert(depth.PopBack()));
			default:
				Try!(Insert(new:alloc RegexCharacterNode() { char = c }));
			}

			return .Ok;
		}

		var iter = string.GetEnumerator();
		Queue<char8> nesting = scope .(8);
		while (iter.Index < iter.Length)
			switch (Parse(ref iter, nesting))
			{
			case .Ok:
			case .Err(let err):
				return .Err((err, iter.Index));
			}

		if (!nesting.IsEmpty)
			return .Err((RegexParseError.GroupNotClosed(nesting.Back), iter.Index));
		if (depth.Count == 2) CloseEnum();
		Debug.Assert(depth.Count == 1);
		return depth.Front;
	}
}