use mlx_rs::{Array, array};

fn main() {
    let a = array!(1.0f32);
    let b = mlx_rs::ops::ones::<f32>(&[384, 384]).unwrap();
    println!("OK");
}
