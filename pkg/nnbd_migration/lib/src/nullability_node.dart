// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:meta/meta.dart';
import 'package:nnbd_migration/instrumentation.dart';
import 'package:nnbd_migration/nullability_state.dart';
import 'package:nnbd_migration/src/edit_plan.dart';
import 'package:nnbd_migration/src/expression_checks.dart';
import 'package:nnbd_migration/src/hint_action.dart';
import 'package:nnbd_migration/src/nullability_node_target.dart';

import 'edge_origin.dart';

/// Base class for steps that occur as part of downstream propagation, where the
/// nullability of a node is changed to a new state.
abstract class DownstreamPropagationStep extends PropagationStep
    implements DownstreamPropagationStepInfo {
  @override
  NullabilityNodeMutable targetNode;

  /// The state that the node's nullability was changed to.
  ///
  /// Any propagation step that took effect should have a non-null value here.
  /// Propagation steps that are pending but have not taken effect yet, or that
  /// never had an effect (e.g. because an edge was not triggered) will have a
  /// `null` value for this field.
  Nullability newState;

  DownstreamPropagationStep();

  @override
  DownstreamPropagationStep get principalCause;
}

/// Base class for steps that occur as part of propagating exact nullability
/// upstream through the nullability graph.
abstract class ExactNullablePropagationStep extends DownstreamPropagationStep {
  ExactNullablePropagationStep();
}

/// Conditions of the "lateness" of a [NullabilityNode].
enum LateCondition {
  /// The associated [NullabilityNode] does not represent the type of a late
  /// variable.
  notLate,

  /// The associated [NullabilityNode] represents the type of a late variable,
  /// due to a `/*late*/` hint.
  lateDueToHint,

  /// The associated [NullabilityNode] represents an variable which is possibly
  /// late, due to the late-inferring algorithm.
  possiblyLate,

  /// The associated [NullabilityNode] represents an variable which is possibly
  /// late, due to being assigned in a function passed to a call to the test
  /// package's `setUp` function.
  possiblyLateDueToTestSetup,
}

/// Data structure to keep track of the relationship from one [NullabilityNode]
/// object to another [NullabilityNode] that is "downstream" from it (meaning
/// that if the former node is nullable, then the latter node will either have
/// to be nullable, or null checks will have to be added).
class NullabilityEdge implements EdgeInfo {
  @override
  final NullabilityNode destinationNode;

  /// A set of upstream nodes.  By convention, the first node is the source node
  /// and the other nodes are "guards".  The destination node will only need to
  /// be made nullable if all the upstream nodes are nullable.
  final List<NullabilityNode> upstreamNodes;

  final _NullabilityEdgeKind _kind;

  /// The location in the source code that caused this edge to be built.
  final CodeReference codeReference;

  final String description;

  /// Whether this edge is the result of an uninitialized variable declaration.
  final bool isUninit;

  /// Whether this edge is the result of an assignment within the test package's
  /// `setUp` function.
  final bool isSetupAssignment;

  NullabilityEdge._(
      this.destinationNode, this.upstreamNodes, this._kind, this.description,
      {this.codeReference, this.isUninit, this.isSetupAssignment});

  @override
  Iterable<NullabilityNode> get guards => upstreamNodes.skip(1);

  /// Indicates whether it's possible for migration to cope with this edge being
  /// unsatisfied by inserting a null check.  Graph propagation favors
  /// satisfying uncheckable edges over satisfying hard edges.
  bool get isCheckable =>
      _kind == _NullabilityEdgeKind.soft || _kind == _NullabilityEdgeKind.hard;

  @override
  bool get isHard =>
      _kind == _NullabilityEdgeKind.hard ||
      _kind == _NullabilityEdgeKind.union ||
      _kind == _NullabilityEdgeKind.uncheckableHard;

  @override
  bool get isSatisfied {
    if (!isTriggered) return true;
    return destinationNode.isNullable;
  }

  @override
  bool get isTriggered {
    for (var upstreamNode in upstreamNodes) {
      if (!upstreamNode.isNullable) return false;
    }
    return true;
  }

  @override
  bool get isUnion => _kind == _NullabilityEdgeKind.union;

  @override
  bool get isUpstreamTriggered {
    if (!isHard) return false;
    return destinationNode.nonNullIntent.isPresent;
  }

  @override
  NullabilityNode get sourceNode => upstreamNodes.first;

  @override
  String toString({NodeToIdMapper idMapper}) {
    var edgeDecorations = <Object>[];
    switch (_kind) {
      case _NullabilityEdgeKind.soft:
        break;
      case _NullabilityEdgeKind.uncheckable:
        edgeDecorations.add('uncheckable');
        break;
      case _NullabilityEdgeKind.uncheckableHard:
        edgeDecorations.add('uncheckableHard');
        break;
      case _NullabilityEdgeKind.hard:
        edgeDecorations.add('hard');
        break;
      case _NullabilityEdgeKind.union:
        edgeDecorations.add('union');
        break;
      case _NullabilityEdgeKind.dummy:
        edgeDecorations.add('dummy');
        break;
    }
    edgeDecorations.addAll(guards);
    var edgeDecoration =
        edgeDecorations.isEmpty ? '' : '-(${edgeDecorations.join(', ')})';
    return '${sourceNode.toString(idMapper: idMapper)} $edgeDecoration-> '
        '${destinationNode.toString(idMapper: idMapper)}';
  }
}

/// Data structure to keep track of the relationship between [NullabilityNode]
/// objects.
class NullabilityGraph {
  /// Set this const to `true` to dump the nullability graph just before
  /// propagation.
  static const _debugBeforePropagation = false;

  /// Set this const to `true` to dump the nullability graph just before
  /// propagation.
  static const _debugAfterPropagation = false;

  final NullabilityMigrationInstrumentation /*?*/ instrumentation;

  /// Returns a [NullabilityNode] that is a priori nullable.
  ///
  /// Propagation of nullability always proceeds downstream starting at this
  /// node.
  final NullabilityNode always;

  /// Returns a [NullabilityNode] that is a priori non-nullable.
  ///
  /// Propagation of nullability always proceeds upstream starting at this
  /// node.
  final NullabilityNode never;

  /// Set containing all sources being migrated.
  final _sourcesBeingMigrated = <Source>{};

  /// Set containing paths to all sources being migrated.
  final _pathsBeingMigrated = <String>{};

  /// A set containing all of the nodes in the graph.
  final Set<NullabilityNode> nodes = {};

  NullabilityGraph({this.instrumentation})
      : always = _NullabilityNodeImmutable('always', true),
        never = _NullabilityNodeImmutable('never', false);

  /// Records that [sourceNode] is immediately upstream from [destinationNode].
  ///
  /// Returns the edge created by the connection.
  NullabilityEdge connect(NullabilityNode sourceNode,
      NullabilityNode destinationNode, EdgeOrigin origin,
      {bool hard = false,
      bool checkable = true,
      List<NullabilityNode> guards = const []}) {
    var upstreamNodes = [sourceNode, ...guards];
    var kind = hard
        ? checkable
            ? _NullabilityEdgeKind.hard
            : _NullabilityEdgeKind.uncheckableHard
        : checkable
            ? _NullabilityEdgeKind.soft
            : _NullabilityEdgeKind.uncheckable;
    return _connect(upstreamNodes, destinationNode, kind, origin);
  }

  /// Records that [sourceNode] is immediately upstream from [always], via a
  /// dummy edge.
  NullabilityEdge connectDummy(NullabilityNode sourceNode, EdgeOrigin origin) =>
      _connect([sourceNode], always, _NullabilityEdgeKind.dummy, origin);

  /// Prints out a representation of the graph nodes.  Useful in debugging
  /// broken tests.
  void debugDump() {
    Set<NullabilityNode> visitedNodes = {};
    Map<NullabilityNode, String> shortNames = {};
    int counter = 0;
    String nameNode(NullabilityNode node) {
      if (node.isImmutable) {
        var name = 'n${counter++}';
        print('  $name [label="$node" shape=none]');
        return name;
      }
      var name = shortNames[node];
      if (name == null) {
        shortNames[node] = name = 'n${counter++}';
        String styleSuffix = node.isNullable ? ' style=filled' : '';
        String intentSuffix =
            node.nonNullIntent.isPresent ? ', non-null intent' : '';
        String label = '$node (${node._nullability}$intentSuffix)';
        print('  $name [label="$label"$styleSuffix]');
        if (node is NullabilityNodeCompound) {
          for (var component in node._components) {
            print('  ${nameNode(component)} -> $name [style=dashed]');
          }
        }
      }
      return name;
    }

    void visitNode(NullabilityNode node) {
      if (!visitedNodes.add(node)) return;
      for (var edge in node._upstreamEdges) {
        String suffix;
        if (edge.isUnion) {
          suffix = ' [label="union"]';
        } else if (edge.isHard) {
          suffix = ' [label="hard"]';
        } else if (edge.isCheckable) {
          suffix = '';
        } else {
          suffix = ' [label="uncheckable"]';
        }
        var upstreamNodes = edge.upstreamNodes;
        if (upstreamNodes.length == 1) {
          print(
              '  ${nameNode(upstreamNodes.single)} -> ${nameNode(node)}$suffix');
        } else {
          var tmpName = 'n${counter++}';
          print('  $tmpName [label=""]');
          print('  $tmpName -> ${nameNode(node)}$suffix}');
          for (var upstreamNode in upstreamNodes) {
            print('  ${nameNode(upstreamNode)} -> $tmpName');
          }
        }
      }
    }

    print('digraph G {');
    print('  rankdir="LR"');
    visitNode(always);
    visitNode(never);
    for (var node in nodes) {
      visitNode(node);
    }
    print('}');
  }

  /// Determine if [source] is in the code being migrated.
  bool isBeingMigrated(Source source) {
    return _sourcesBeingMigrated.contains(source);
  }

  bool isPathBeingMigrated(String path) {
    return _pathsBeingMigrated.contains(path);
  }

  /// Creates a graph edge that will try to force the given [node] to be
  /// non-nullable.
  NullabilityEdge makeNonNullable(NullabilityNode node, EdgeOrigin origin,
      {bool hard = true, List<NullabilityNode> guards = const []}) {
    return connect(node, never, origin, hard: hard, guards: guards);
  }

  /// Creates union edges that will guarantee that the given [node] is
  /// non-nullable.
  void makeNonNullableUnion(NullabilityNode node, EdgeOrigin origin) {
    union(node, never, origin);
  }

  /// Creates a graph edge that will try to force the given [node] to be
  /// nullable.
  void makeNullable(NullabilityNode node, EdgeOrigin origin,
      {List<NullabilityNode> guards = const []}) {
    connect(always, node, origin, guards: guards);
  }

  /// Creates a `union` graph edge that will try to force the given [node] to be
  /// nullable.  This is a stronger signal than [makeNullable] (it overrides
  /// [makeNonNullable]).
  void makeNullableUnion(NullabilityNode node, EdgeOrigin origin) {
    union(always, node, origin);
  }

  /// Record source as code that is being migrated.
  void migrating(Source source) {
    _sourcesBeingMigrated.add(source);
    _pathsBeingMigrated.add(source.fullName);
  }

  /// Determines the nullability of each node in the graph by propagating
  /// nullability information from one node to another.
  PropagationResult propagate() {
    if (_debugBeforePropagation) debugDump();
    var propagationState = _PropagationState(always, never).result;
    if (_debugAfterPropagation) debugDump();
    return propagationState;
  }

  /// Records that nodes [x] and [y] should have exactly the same nullability.
  void union(NullabilityNode x, NullabilityNode y, EdgeOrigin origin) {
    _connect([x], y, _NullabilityEdgeKind.union, origin);
    _connect([y], x, _NullabilityEdgeKind.union, origin);
  }

  /// Update the graph after an edge has been added or removed.
  void update() {
    //
    // Reset the state of the nodes.
    //
    // This is inefficient because we reset the state of some nodes more than
    // once, but not all nodes are reachable from both `never` and `always`, so
    // we need to traverse the graph from both directions.
    //
    for (var node in nodes) {
      node.resetState();
    }
    //
    // Reset the state of the listener.
    //
    instrumentation.prepareForUpdate();
    //
    // Re-run the propagation step.
    //
    propagate();
  }

  NullabilityEdge _connect(
      List<NullabilityNode> upstreamNodes,
      NullabilityNode destinationNode,
      _NullabilityEdgeKind kind,
      EdgeOrigin origin) {
    var isUninit = origin?.kind == EdgeOriginKind.fieldNotInitialized ||
        origin?.kind == EdgeOriginKind.implicitNullInitializer ||
        origin?.kind == EdgeOriginKind.uninitializedRead;
    var isSetupAssignment =
        origin is ExpressionChecksOrigin && origin.isSetupAssignment;
    var edge = NullabilityEdge._(
        destinationNode, upstreamNodes, kind, origin?.description,
        codeReference: origin?.codeReference,
        isUninit: isUninit,
        isSetupAssignment: isSetupAssignment);
    instrumentation?.graphEdge(edge, origin);
    for (var upstreamNode in upstreamNodes) {
      _connectDownstream(upstreamNode, edge);
    }
    destinationNode._upstreamEdges.add(edge);
    nodes.addAll(upstreamNodes);
    nodes.add(destinationNode);
    return edge;
  }

  void _connectDownstream(NullabilityNode upstreamNode, NullabilityEdge edge) {
    upstreamNode._downstreamEdges.add(edge);
    if (upstreamNode is NullabilityNodeCompound) {
      for (var component in upstreamNode._components) {
        _connectDownstream(component, edge);
      }
    }
  }
}

/// Same as [NullabilityGraph], but extended with extra methods for easier
/// testing.
@visibleForTesting
class NullabilityGraphForTesting extends NullabilityGraph {
  final List<NullabilityEdge> _allEdges = [];

  final Map<NullabilityEdge, EdgeOrigin> _edgeOrigins = {};

  /// Iterates through all edges in the graph.
  @visibleForTesting
  Iterable<NullabilityEdge> getAllEdges() {
    return _allEdges;
  }

  /// Retrieves the [EdgeOrigin] object that was used to create [edge].
  @visibleForTesting
  EdgeOrigin getEdgeOrigin(NullabilityEdge edge) => _edgeOrigins[edge];

  @override
  NullabilityEdge _connect(
      List<NullabilityNode> upstreamNodes,
      NullabilityNode destinationNode,
      _NullabilityEdgeKind kind,
      EdgeOrigin origin) {
    var edge = super._connect(upstreamNodes, destinationNode, kind, origin);
    _allEdges.add(edge);
    _edgeOrigins[edge] = origin;
    return edge;
  }
}

/// Representation of a single node in the nullability inference graph.
///
/// Initially, this is just a wrapper over constraint variables, and the
/// nullability inference graph is encoded into the wrapped constraint
/// variables.  Over time this will be replaced by a first class representation
/// of the nullability inference graph.
abstract class NullabilityNode implements NullabilityNodeInfo {
  LateCondition _lateCondition = LateCondition.notLate;

  @override
  final hintActions = <HintActionKind, Map<int, List<AtomicEdit>>>{};

  bool _isPossiblyOptional = false;

  /// List of [NullabilityEdge] objects describing this node's relationship to
  /// other nodes that are "downstream" from it (meaning that if a key node is
  /// nullable, then all the nodes in the corresponding value will either have
  /// to be nullable, or null checks will have to be added).
  final _downstreamEdges = <NullabilityEdge>[];

  /// List of edges that have this node as their destination.
  final _upstreamEdges = <NullabilityEdge>[];

  /// List of compound nodes wrapping this node.
  final List<NullabilityNodeCompound> outerCompoundNodes =
      <NullabilityNodeCompound>[];

  /// Creates a [NullabilityNode] representing the nullability of a variable
  /// whose type comes from an already-migrated library.
  factory NullabilityNode.forAlreadyMigrated(NullabilityNodeTarget target) =>
      _NullabilityNodeSimple(target);

  /// Creates a [NullabilityNode] representing the nullability of an expression
  /// which is nullable iff two other nullability nodes are both nullable.
  ///
  /// The caller is required to create the appropriate graph edges to ensure
  /// that the appropriate relationship between the nodes' nullabilities holds.
  factory NullabilityNode.forGLB() => _NullabilityNodeSimple(
      NullabilityNodeTarget.text('(greatest lower bound)'));

  /// Creates a [NullabilityNode] representing the nullability of a variable
  /// whose type is determined by the `??` operator.
  factory NullabilityNode.forIfNotNull(AstNode node) => _NullabilityNodeSimple(
      NullabilityNodeTarget.text('?? operator').withCodeRef(node));

  /// Creates a [NullabilityNode] representing the nullability of a variable
  /// whose type is determined by type inference.
  factory NullabilityNode.forInferredType(NullabilityNodeTarget target) =>
      _NullabilityNodeSimple(target);

  /// Creates a [NullabilityNode] representing the nullability of an
  /// expression which is nullable iff either [a] or [b] is nullable.
  factory NullabilityNode.forLUB(NullabilityNode left, NullabilityNode right) =
      NullabilityNodeForLUB._;

  /// Creates a [NullabilityNode] representing the nullability of a type
  /// substitution where [outerNode] is the nullability node for the type
  /// variable being eliminated by the substitution, and [innerNode] is the
  /// nullability node for the type being substituted in its place.
  ///
  /// If either [innerNode] or [outerNode] is `null`, then the other node is
  /// returned.
  factory NullabilityNode.forSubstitution(
      NullabilityNode innerNode, NullabilityNode outerNode) {
    if (innerNode == null) return outerNode;
    if (outerNode == null) return innerNode;
    return NullabilityNodeForSubstitution._(innerNode, outerNode);
  }

  /// Creates a [NullabilityNode] representing the nullability of a type
  /// annotation appearing explicitly in the user's program.
  factory NullabilityNode.forTypeAnnotation(NullabilityNodeTarget target) =>
      _NullabilityNodeSimple(target);

  NullabilityNode._();

  @override
  CodeReference get codeReference => null;

  /// Gets a string that can be appended to a type name during debugging to help
  /// annotate the nullability of that type.
  String get debugSuffix => '?($this)';

  /// Gets a name for the nullability node that is suitable for display to the
  /// user.
  String get displayName;

  Iterable<EdgeInfo> get downstreamEdges => _downstreamEdges;

  /// After nullability propagation, this getter can be used to query whether
  /// the type associated with this node should be considered "exact nullable".
  @visibleForTesting
  bool get isExactNullable;

  /// After nullability propagation, this getter can be used to query whether
  /// the type associated with this node should be considered nullable.
  @override
  bool get isNullable;

  /// Indicates whether this node is associated with a named parameter for which
  /// nullability migration needs to decide whether it is optional or required.
  bool get isPossiblyOptional => _isPossiblyOptional;

  /// Indicates whether this node is associated with a variable declaration
  /// which should be annotated with "late".
  LateCondition get lateCondition => _lateCondition;

  /// After nullability propagation, this getter can be used to query the node's
  /// non-null intent state.
  NonNullIntent get nonNullIntent;

  @override
  Iterable<EdgeInfo> get upstreamEdges => _upstreamEdges;

  @override
  UpstreamPropagationStep get whyNotNullable;

  Nullability get _nullability;

  /// Records the fact that an invocation was made to a function with named
  /// parameters, and the named parameter associated with this node was not
  /// supplied.
  void recordNamedParameterNotSupplied(List<NullabilityNode> guards,
      NullabilityGraph graph, NamedParameterNotSuppliedOrigin origin) {
    if (isPossiblyOptional) {
      graph.connect(graph.always, this, origin, guards: guards);
    }
  }

  /// Reset the state of this node to what it was before the graph was solved.
  void resetState();

  String toString({NodeToIdMapper idMapper}) {
    var name = displayName;
    if (idMapper == null) {
      return name;
    } else {
      return '${idMapper.idForNode(this)}: $name';
    }
  }

  /// Tracks the possibility that this node is associated with a named parameter
  /// for which nullability migration needs to decide whether it is optional or
  /// required.
  void trackPossiblyOptional() {
    _isPossiblyOptional = true;
  }
}

/// Base class for nullability nodes that are nullable if at least one of a set
/// of other nodes is nullable, and non-nullable otherwise; the set of other
/// nodes are called "components".
abstract class NullabilityNodeCompound extends NullabilityNodeMutable {
  NullabilityNodeCompound() : super._();

  /// A map describing each of the node's components by name.
  Map<String, NullabilityNode> get componentsByName;

  @override
  bool get isExactNullable => _components.any((c) => c.isExactNullable);

  @override
  bool get isNullable => _components.any((c) => c.isNullable);

  Iterable<NullabilityNode> get _components;
}

/// Derived class for nullability nodes that arise from the least-upper-bound
/// implied by a conditional expression.
class NullabilityNodeForLUB extends NullabilityNodeCompound {
  final NullabilityNode left;

  final NullabilityNode right;

  NullabilityNodeForLUB._(this.left, this.right) {
    left.outerCompoundNodes.add(this);
    right.outerCompoundNodes.add(this);
  }

  @override
  Map<String, NullabilityNode> get componentsByName =>
      {'left': left, 'right': right};

  @override
  String get displayName => '${left.displayName} or ${right.displayName}';

  @override
  Iterable<NullabilityNode> get _components => [left, right];

  @override
  void resetState() {
    left.resetState();
    right.resetState();
  }
}

/// Derived class for nullability nodes that arise from type variable
/// substitution.
class NullabilityNodeForSubstitution extends NullabilityNodeCompound
    implements SubstitutionNodeInfo {
  @override
  final NullabilityNode innerNode;

  @override
  final NullabilityNode outerNode;

  NullabilityNodeForSubstitution._(this.innerNode, this.outerNode) {
    innerNode.outerCompoundNodes.add(this);
    outerNode.outerCompoundNodes.add(this);
  }

  @override
  Map<String, NullabilityNode> get componentsByName =>
      {'inner': innerNode, 'outer': outerNode};

  @override
  String get displayName =>
      '${innerNode.displayName} or ${outerNode.displayName}';

  @override
  Iterable<NullabilityNode> get _components => [innerNode, outerNode];

  @override
  void resetState() {
    innerNode.resetState();
    outerNode.resetState();
  }
}

/// Base class for nullability nodes whose state can be mutated safely.
///
/// Nearly all nullability nodes derive from this class; the only exceptions are
/// the fixed nodes "always "never".
abstract class NullabilityNodeMutable extends NullabilityNode {
  Nullability _nullability;

  NonNullIntent _nonNullIntent;

  DownstreamPropagationStep _whyNullable;

  UpstreamPropagationStep _whyNotNullable;

  NullabilityNodeMutable._(
      {Nullability initialNullability = Nullability.nonNullable})
      : _nullability = initialNullability,
        _nonNullIntent = NonNullIntent.none,
        super._();

  @override
  bool get isExactNullable => _nullability.isExactNullable;

  @override
  bool get isImmutable => false;

  @override
  bool get isNullable => _nullability.isNullable;

  @override
  NonNullIntent get nonNullIntent => _nonNullIntent;

  @override
  UpstreamPropagationStep get whyNotNullable => _whyNotNullable;

  @override
  DownstreamPropagationStepInfo get whyNullable => _whyNullable;

  @override
  void resetState() {
    _nullability = Nullability.nonNullable;
    _nonNullIntent = NonNullIntent.none;
    _whyNullable = null;
  }
}

/// Information produced by [NullabilityGraph.propagate] about the results of
/// graph propagation.
class PropagationResult {
  /// A list of all edges that couldn't be satisfied.  May contain duplicates.
  final List<NullabilityEdge> unsatisfiedEdges = [];

  /// A list of all substitution nodes that couldn't be satisfied.
  final List<NullabilityNodeForSubstitution> unsatisfiedSubstitutions = [];

  PropagationResult._();
}

/// Class representing a step taken by the nullability propagation algorithm.
abstract class PropagationStep implements PropagationStepInfo {
  PropagationStep();

  /// The location in the source code that caused this step to be necessary,
  /// or `null` if not known.
  CodeReference get codeReference => null;

  /// The previous propagation step that led to this one, or `null` if there was
  /// no previous step.
  PropagationStep get principalCause;

  @override
  String toString({NodeToIdMapper idMapper});
}

/// Propagation step where we consider mark one of the components of a
/// substitution node as nullable because the substitution node itself is
/// nullable.
class ResolveSubstitutionPropagationStep extends ExactNullablePropagationStep {
  @override
  final DownstreamPropagationStep principalCause;

  /// The substitution node that needed resolution.
  final NullabilityNodeForSubstitution node;

  ResolveSubstitutionPropagationStep(this.principalCause, this.node);

  @override
  EdgeInfo get edge => null;

  @override
  String toString({NodeToIdMapper idMapper}) =>
      '${targetNode.toString(idMapper: idMapper)} becomes $newState due to '
      '${node.toString(idMapper: idMapper)}';
}

/// Propagation step where we mark the destination of an edge as nullable, due
/// to its sources becoming nullable.
class SimpleDownstreamPropagationStep extends DownstreamPropagationStep {
  @override
  final DownstreamPropagationStep principalCause;

  @override
  final NullabilityEdge edge;

  SimpleDownstreamPropagationStep(this.principalCause, this.edge);

  @override
  CodeReference get codeReference => edge.codeReference;

  @override
  String toString({NodeToIdMapper idMapper}) =>
      '${targetNode.toString(idMapper: idMapper)} becomes $newState due to '
      '${edge.toString(idMapper: idMapper)}';
}

/// Propagation step where we mark the source of an edge as exact nullable, due
/// to its destination becoming exact nullable.
class SimpleExactNullablePropagationStep extends ExactNullablePropagationStep {
  @override
  final ExactNullablePropagationStep principalCause;

  @override
  final NullabilityEdge edge;

  SimpleExactNullablePropagationStep(this.principalCause, this.edge);

  @override
  String toString({NodeToIdMapper idMapper}) =>
      '${targetNode.toString(idMapper: idMapper)} becomes $newState due to '
      '${edge.toString(idMapper: idMapper)}';
}

/// Propagation step where we mark a node as having non-null intent due to it
/// being upstream from another node with non-null intent.
class UpstreamPropagationStep extends PropagationStep
    implements UpstreamPropagationStepInfo {
  @override
  final UpstreamPropagationStep principalCause;

  /// The node being marked as having non-null intent.
  final NullabilityNode node;

  /// The new state of the node's non-null intent.
  final NonNullIntent newNonNullIntent;

  /// The nullability edge connecting [node] to the node it is upstream from, if
  /// any.
  final NullabilityEdge edge;

  @override
  final bool isStartingPoint;

  UpstreamPropagationStep(
      this.principalCause, this.node, this.newNonNullIntent, this.edge,
      {this.isStartingPoint = false});

  @override
  CodeReference get codeReference => edge?.codeReference;

  @override
  String toString({NodeToIdMapper idMapper}) =>
      '${node.toString(idMapper: idMapper)} becomes $newNonNullIntent';
}

/// Kinds of nullability edges
enum _NullabilityEdgeKind {
  /// Soft edge.  Propagates nullability downstream only.  May be overridden by
  /// suggestions that the user intends non-nullability.
  soft,

  /// Uncheckable edge.  Propagates nullability downstream only.  May not be
  /// overridden by suggestions that the user intends non-nullability.
  uncheckable,

  /// Hard edge.  Propagates nullability downstream and non-nullability
  /// upstream.
  hard,

  /// Union edge.  Indicates that two nodes should have exactly the same
  /// nullability.
  union,

  /// Uncheckable hard edge.  Propagates nullability downstream and
  /// non-nullability upstream.  May not be overridden by suggestions that the
  /// user intends non-nullability.
  uncheckableHard,

  /// Dummy edge.  Indicates that two edges are connected in a way that should
  /// not propagate (non-)nullability in either direction.
  dummy,
}

class _NullabilityNodeImmutable extends NullabilityNode {
  @override
  final String displayName;

  @override
  final bool isNullable;

  _NullabilityNodeImmutable(this.displayName, this.isNullable) : super._();

  @override
  String get debugSuffix => isNullable ? '?' : '';

  @override
  Map<HintActionKind, Map<int, List<AtomicEdit>>> get hintActions => const {};

  @override
  // Note: the node "always" is not exact nullable, because exact nullability is
  // a concept for contravariant generics which propagates upstream instead of
  // downstream. "always" is not a contravariant generic, and does not have any
  // upstream nodes, so it should not be considered *exact* nullable.
  bool get isExactNullable => false;

  @override
  bool get isImmutable => true;

  @override
  NonNullIntent get nonNullIntent =>
      isNullable ? NonNullIntent.none : NonNullIntent.direct;

  @override
  UpstreamPropagationStep get whyNotNullable => null;

  @override
  DownstreamPropagationStepInfo get whyNullable => null;

  @override
  Nullability get _nullability =>
      isNullable ? Nullability.ordinaryNullable : Nullability.nonNullable;

  @override
  void resetState() {
    // There is no state to reset.
  }
}

class _NullabilityNodeSimple extends NullabilityNodeMutable {
  final NullabilityNodeTarget target;

  _NullabilityNodeSimple(this.target) : super._();

  @override
  CodeReference get codeReference => target.codeReference;

  @override
  String get displayName => target.displayName;
}

/// Workspace for performing graph propagation.
///
/// Graph propagation is performed immediately upon construction, so as soon as
/// the caller has constructed this object, the graph has been propagated and
/// the results of propagation can be retrieved from [result].
class _PropagationState {
  /// The result of propagation, for sharing with the client.
  final PropagationResult result = PropagationResult._();

  /// The graph's one and only "always" node.
  final NullabilityNode _always;

  /// The graph's one and only "never" node.
  final NullabilityNode _never;

  /// During any given stage of nullability propagation, a queue of all the
  /// edges that need to be examined before the stage is complete.
  final Queue<SimpleDownstreamPropagationStep> _pendingDownstreamSteps =
      Queue();

  /// During execution of [_propagateDownstream], a list of all the substitution
  /// nodes that have not yet been resolved.
  List<ResolveSubstitutionPropagationStep> _pendingSubstitutions = [];

  _PropagationState(this._always, this._never) {
    _propagateUpstream();
    _propagateDownstream();
  }

  /// Propagates nullability downstream.
  void _propagateDownstream() {
    assert(_pendingDownstreamSteps.isEmpty);
    for (var edge in _always._downstreamEdges) {
      _pendingDownstreamSteps.add(SimpleDownstreamPropagationStep(null, edge));
    }
    while (true) {
      while (_pendingDownstreamSteps.isNotEmpty) {
        var step = _pendingDownstreamSteps.removeFirst();
        var edge = step.edge;
        if (!edge.isTriggered) continue;
        var node = edge.destinationNode;
        if (edge.isUninit && !node.isNullable) {
          // [edge] is an edge from always to an uninitialized variable
          // declaration.
          var isSetupAssigned = node.upstreamEdges
              .any((e) => e is NullabilityEdge && e.isSetupAssignment);

          // Whether all downstream edges go to nodes with non-null intent.
          var allDownstreamHaveNonNullIntent = false;
          if (node.downstreamEdges.isNotEmpty) {
            allDownstreamHaveNonNullIntent = node.downstreamEdges.every((e) {
              var destination = e.destinationNode;
              return destination is NullabilityNode &&
                  destination.nonNullIntent.isPresent;
            });
          }
          if (allDownstreamHaveNonNullIntent) {
            node._lateCondition = LateCondition.possiblyLate;
            continue;
          } else if (isSetupAssigned) {
            node._lateCondition = LateCondition.possiblyLateDueToTestSetup;
            continue;
          }
        }
        var nonNullIntent = node.nonNullIntent;
        if (nonNullIntent.isPresent) {
          if (edge.isCheckable) {
            // The node has already been marked as having non-null intent, and
            // the edge can be addressed by adding a null check, so we prefer to
            // leave the edge unsatisfied and let the null check happen.
            result.unsatisfiedEdges.add(edge);
            continue;
          }
          if (nonNullIntent.isDirect) {
            // The node has direct non-null intent so we aren't in a position to
            // mark it as nullable.
            result.unsatisfiedEdges.add(edge);
            continue;
          }
        }
        if (node is NullabilityNodeMutable && !node.isNullable) {
          assert(step.targetNode == null);
          step.targetNode = node;
          step.newState = Nullability.ordinaryNullable;
          _setNullable(step);
          node._lateCondition = LateCondition.notLate;
        }
      }
      if (_pendingSubstitutions.isEmpty) break;
      var oldPendingSubstitutions = _pendingSubstitutions;
      _pendingSubstitutions = [];
      for (var step in oldPendingSubstitutions) {
        _resolvePendingSubstitution(step);
      }
    }
  }

  /// Propagates non-null intent upstream along unconditional control flow
  /// lines.
  void _propagateUpstream() {
    Queue<UpstreamPropagationStep> pendingSteps = Queue();
    pendingSteps.add(UpstreamPropagationStep(
        null, _never, NonNullIntent.direct, null,
        isStartingPoint: true));
    while (pendingSteps.isNotEmpty) {
      var cause = pendingSteps.removeFirst();
      var pendingNode = cause.node;
      for (var edge in pendingNode._upstreamEdges) {
        // We only propagate for nodes that are "upstream triggered".  At this
        // point of propagation, a node is upstream triggered if it is hard.
        assert(edge.isUpstreamTriggered == edge.isHard);
        if (!edge.isHard) continue;
        var node = edge.sourceNode;
        if (node is NullabilityNodeMutable) {
          var oldNonNullIntent = node._nonNullIntent;
          NonNullIntent newNonNullIntent;
          if (edge.isUnion && edge.destinationNode == _never) {
            // If a node is unioned with "never" then it's considered to have
            // direct non-null intent.
            newNonNullIntent = NonNullIntent.direct;
          } else {
            newNonNullIntent = oldNonNullIntent.addIndirect();
          }
          var step =
              UpstreamPropagationStep(cause, node, newNonNullIntent, edge);
          _setNonNullIntent(step);
          if (!oldNonNullIntent.isPresent) {
            // We did not previously have non-null intent, so we need to
            // propagate.
            pendingSteps.add(step);
          }
        }
      }
      // If any compound node is forced to be non-nullable by this change,
      // propagate to it.
      for (var node in pendingNode.outerCompoundNodes) {
        if (node._components
            .any((component) => !component.nonNullIntent.isPresent)) {
          continue;
        }
        var oldNonNullIntent = node._nonNullIntent;
        var newNonNullIntent = oldNonNullIntent.addIndirect();
        var step = UpstreamPropagationStep(cause, node, newNonNullIntent, null);
        _setNonNullIntent(step);
        if (!oldNonNullIntent.isPresent) {
          // We did not previously have non-null intent, so we need to
          // propagate.
          pendingSteps.add(step);
        }
      }
    }
  }

  void _resolvePendingSubstitution(ResolveSubstitutionPropagationStep step) {
    NullabilityNodeForSubstitution substitutionNode = step.node;
    assert(substitutionNode._nullability.isNullable);
    // If both nodes pointed to by the substitution node have non-null intent,
    // then no resolution is needed; the substitution node can’t be satisfied.
    if (substitutionNode.innerNode.nonNullIntent.isPresent &&
        substitutionNode.outerNode.nonNullIntent.isPresent) {
      result.unsatisfiedSubstitutions.add(substitutionNode);
      return;
    }

    // Otherwise, if the outer node is in a nullable state, then no resolution
    // is needed because the substitution node is already satisfied.
    if (substitutionNode.outerNode.isNullable) {
      return;
    }

    // Otherwise, if the inner node has non-null intent, then we set the outer
    // node to the ordinary nullable state.
    if (substitutionNode.innerNode.nonNullIntent.isPresent) {
      assert(step.targetNode == null);
      step.targetNode = substitutionNode.outerNode as NullabilityNodeMutable;
      step.newState = Nullability.ordinaryNullable;
      _setNullable(step);
      return;
    }

    // Otherwise, we set the inner node to the exact nullable state, and we
    // propagate this state upstream as far as possible using the following
    // rule: if there is an edge A → B, where A is in the undetermined or
    // ordinary nullable state, and B is in the exact nullable state, then A’s
    // state is changed to exact nullable.
    var pendingExactNullableSteps = <SimpleExactNullablePropagationStep>[];
    var node = substitutionNode.innerNode;
    if (node is NullabilityNodeMutable) {
      assert(step.targetNode == null);
      step.targetNode = node;
      step.newState = Nullability.exactNullable;
      var oldNullability = _setNullable(step);
      if (!oldNullability.isExactNullable) {
        // Was not previously in the "exact nullable" state.  Need to
        // propagate.
        for (var edge in node._upstreamEdges) {
          pendingExactNullableSteps
              .add(SimpleExactNullablePropagationStep(step, edge));
        }

        // TODO(mfairhurst): should this propagate back up outerContainerNodes?
      }
    }

    while (pendingExactNullableSteps.isNotEmpty) {
      var step = pendingExactNullableSteps.removeLast();
      var edge = step.edge;
      var node = edge.sourceNode;
      if (node is NullabilityNodeMutable &&
          !edge.isCheckable &&
          !node.nonNullIntent.isPresent) {
        assert(step.targetNode == null);
        step.targetNode = node;
        step.newState = Nullability.exactNullable;
        var oldNullability = _setNullable(step);
        if (!oldNullability.isExactNullable) {
          // Was not previously in the "exact nullable" state.  Need to
          // propagate.
          for (var edge in node._upstreamEdges) {
            pendingExactNullableSteps
                .add(SimpleExactNullablePropagationStep(step, edge));
          }
        }
      }
    }
  }

  void _setNonNullIntent(UpstreamPropagationStep step) {
    var node = step.node as NullabilityNodeMutable;
    var newNonNullIntent = step.newNonNullIntent;
    var oldNonNullIntent = node.nonNullIntent;
    node._nonNullIntent = newNonNullIntent;
    if (!oldNonNullIntent.isPresent) {
      node._whyNotNullable = step;
    }
  }

  Nullability _setNullable(DownstreamPropagationStep step) {
    var node = step.targetNode;
    var newState = step.newState;
    var oldState = node._nullability;
    node._nullability = newState;
    if (!oldState.isNullable) {
      node._whyNullable = step;
      // Was not previously nullable, so we need to propagate.
      for (var edge in node._downstreamEdges) {
        _pendingDownstreamSteps
            .add(SimpleDownstreamPropagationStep(step, edge));
      }
      if (node is NullabilityNodeForSubstitution) {
        _pendingSubstitutions
            .add(ResolveSubstitutionPropagationStep(step, node));
      }
    }
    return oldState;
  }
}
