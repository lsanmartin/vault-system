/// Language Agent Tree Search — MCTS aplicado a acciones de agente.
/// Explora árbol de decisiones, evalúa nodos, y retorna la mejor ruta.

use std::collections::HashMap;

/// Un nodo en el árbol de búsqueda
#[derive(Clone, Debug, serde::Serialize)]
pub struct LatsNode {
    pub id: String,
    pub action: String,
    pub depth: u32,
    pub visits: u32,
    pub value: f64,          // recompensa acumulada
    pub children: Vec<String>,
}

/// Resultado de una expansión LATS
#[derive(serde::Serialize)]
pub struct LatsResult {
    pub best_path: Vec<String>,
    pub best_score: f64,
    pub nodes_explored: u32,
    pub iterations: u32,
}

/// Ejecuta búsqueda LATS para un objetivo dado.
/// `actions` son las herramientas/tools disponibles como strings JSON.
/// `max_iterations`: límite de iteraciones MCTS.
/// `exploration_weight`: controla exploración vs explotación (típico: 1.4).
pub fn lats_search(
    goal: &str,
    actions: &[String],
    max_iterations: u32,
    exploration_weight: f64,
) -> LatsResult {
    let mut nodes: HashMap<String, LatsNode> = HashMap::new();
    let root_id = "root".to_string();

    nodes.insert(root_id.clone(), LatsNode {
        id: root_id.clone(),
        action: "START".into(),
        depth: 0,
        visits: 0,
        value: 0.0,
        children: Vec::new(),
    });

    // Expandir nodo raíz con todas las acciones disponibles
    for (i, action) in actions.iter().enumerate() {
        let child_id = format!("n_{}_{}", 1, i);
        nodes.get_mut(&root_id).unwrap().children.push(child_id.clone());
        nodes.insert(child_id.clone(), LatsNode {
            id: child_id,
            action: action.clone(),
            depth: 1,
            visits: 0,
            value: 0.0,
            children: Vec::new(),
        });
    }

    let mut nodes_explored = 0u32;

    for iter in 0..max_iterations {
        // 1. Selección: elegir nodo hoja con mayor UCB
        let leaf_path = select_leaf(&root_id, &nodes, exploration_weight);

        // 2. Expansión: desde la hoja, expandir con acciones restantes
        if let Some(leaf_id) = leaf_path.last() {
            let leaf_depth = nodes[leaf_id].depth;
            if leaf_depth < 3 && nodes[leaf_id].children.is_empty() {
                let remaining: Vec<&String> = actions.iter()
                    .filter(|a| !leaf_path.iter().any(|id| nodes[id].action == **a))
                    .collect();
                for (i, action) in remaining.iter().enumerate() {
                    let child_id = format!("n_{}_{}", iter + 2, i);
                    nodes.get_mut(leaf_id).unwrap().children.push(child_id.clone());
                    nodes.insert(child_id.clone(), LatsNode {
                        id: child_id.clone(),
                        action: (*action).clone(),
                        depth: leaf_depth + 1,
                        visits: 0,
                        value: 0.0,
                        children: Vec::new(),
                    });
                    nodes_explored += 1;
                }
            }

            // 3. Simulación: evaluar la hoja (heurística: profundidad + diversidad)
            let score = simulate_leaf(&leaf_path, &nodes);

            // 4. Backpropagación
            for node_id in &leaf_path {
                if let Some(node) = nodes.get_mut(node_id) {
                    node.visits += 1;
                    node.value += score;
                }
            }
        }

        if nodes_explored > max_iterations * 5 { break; }
    }

    // Encontrar mejor ruta
    let best_path = find_best_path(&root_id, &nodes);
    let best_score = best_path.last()
        .and_then(|id| nodes.get(id.as_str()))
        .map(|n| if n.visits > 0 { n.value / n.visits as f64 } else { 0.0 })
        .unwrap_or(0.0);

    LatsResult {
        best_path: best_path.iter().map(|id| nodes[id].action.clone()).collect(),
        best_score,
        nodes_explored,
        iterations: max_iterations,
    }
}

/// UCB1: Upper Confidence Bound para selección de nodos
fn ucb(node: &LatsNode, parent_visits: u32, exploration_weight: f64) -> f64 {
    if node.visits == 0 {
        return f64::INFINITY; // explorar nodos no visitados primero
    }
    let exploitation = node.value / node.visits as f64;
    let exploration = exploration_weight * ((parent_visits as f64).ln() / node.visits as f64).sqrt();
    exploitation + exploration
}

/// Selecciona la ruta hasta un nodo hoja usando UCB
fn select_leaf(root_id: &str, nodes: &HashMap<String, LatsNode>, c: f64) -> Vec<String> {
    let mut path = vec![root_id.to_string()];
    let mut current = root_id.to_string();

    loop {
        let children = &nodes[&current].children;
        if children.is_empty() { break; }

        let parent_visits = nodes[&current].visits.max(1);
        let best_child = children.iter().max_by(|a, b| {
            let ucb_a = ucb(&nodes[*a], parent_visits, c);
            let ucb_b = ucb(&nodes[*b], parent_visits, c);
            ucb_a.partial_cmp(&ucb_b).unwrap_or(std::cmp::Ordering::Equal)
        });

        match best_child {
            Some(child) => {
                path.push(child.clone());
                current = child.clone();
            }
            None => break,
        }
    }

    path
}

/// Simula el valor de una ruta hoja.
/// Heurística: recompensa la diversidad de acciones y profundidad.
fn simulate_leaf(path: &[String], nodes: &HashMap<String, LatsNode>) -> f64 {
    let depth = path.len() as f64;
    let unique_actions: std::collections::HashSet<&str> = path.iter()
        .filter_map(|id| nodes.get(id))
        .map(|n| n.action.as_str())
        .collect();
    let diversity = unique_actions.len() as f64;

    // Score base: más profundo + más diverso = mejor
    let base = depth * 0.3 + diversity * 0.5;

    // Penalizar caminos muy cortos
    if depth < 2.0 { base * 0.5 } else { base }
}

/// Encuentra la mejor ruta desde la raíz (mayor value/visits)
fn find_best_path(root_id: &str, nodes: &HashMap<String, LatsNode>) -> Vec<String> {
    let mut path = vec![root_id.to_string()];
    let mut current = root_id.to_string();

    loop {
        let children = &nodes[&current].children;
        if children.is_empty() { break; }

        let best = children.iter().max_by(|a, b| {
            let va = if nodes[*a].visits > 0 { nodes[*a].value / nodes[*a].visits as f64 } else { 0.0 };
            let vb = if nodes[*b].visits > 0 { nodes[*b].value / nodes[*b].visits as f64 } else { 0.0 };
            va.partial_cmp(&vb).unwrap_or(std::cmp::Ordering::Equal)
        });

        match best {
            Some(child) => {
                path.push(child.clone());
                current = child.clone();
            }
            None => break,
        }
    }

    path
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lats_basic_search() {
        let actions = vec![
            "vault_search".to_string(),
            "vault_read".to_string(),
            "vault_write".to_string(),
            "vault_get_domain_context".to_string(),
        ];
        let result = lats_search("explorar el vault", &actions, 50, 1.4);
        assert!(!result.best_path.is_empty());
        assert!(result.nodes_explored > 0);
        assert!(result.best_score > 0.0);
    }

    #[test]
    fn test_lats_empty_actions() {
        let result = lats_search("test", &[], 10, 1.4);
        assert_eq!(result.nodes_explored, 0);
    }
}
