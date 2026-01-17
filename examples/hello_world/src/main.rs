use serde::Serialize;

const CAT_JPG: &[u8] = include_bytes!("../cat.jpg");

unsafe extern "C" {
    fn wasi_nn_get_stats() -> i32;
    fn wasi_nn_compute(json_addr: u32, json_size: u32) -> i32;
}

#[derive(Serialize)]
struct InferPayload<'a> {
    id: &'a str,
    inputs: Vec<InputTensor<'a>>,
    outputs: Vec<OutputTensor<'a>>,
}

#[derive(Serialize)]
struct InputTensor<'a> {
    name: &'a str,
    shape: [u32; 4],
    datatype: &'a str,
    data: Vec<f32>,
}

#[derive(Serialize)]
struct OutputTensor<'a> {
    name: &'a str,
}

fn preprocess_bytes(jpg_bytes: &[u8]) -> Vec<f32> {
    const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
    const STD: [f32; 3] = [0.229, 0.224, 0.225];

    let img = image::load_from_memory(jpg_bytes)
        .expect("failed to decode image")
        .to_rgb8();

    let resized = image::imageops::resize(&img, 224, 224, image::imageops::FilterType::Triangle);

    let h = 224usize;
    let w = 224usize;
    let mut out = vec![0f32; 1 * 3 * h * w];

    for y in 0..h {
        for x in 0..w {
            let p = resized.get_pixel(x as u32, y as u32);
            let rgb = [p[0] as f32 / 255.0, p[1] as f32 / 255.0, p[2] as f32 / 255.0];
            for c in 0..3 {
                out[c * (h * w) + y * w + x] = (rgb[c] - MEAN[c]) / STD[c];
            }
        }
    }
    out
}

fn main() {
    let jpg_data = preprocess_bytes(CAT_JPG);
    let infer_payload = InferPayload {
        id: "smoke-test-1",
        inputs: vec![InputTensor {
            name: "INPUT0",
            shape: [1, 3, 224, 224],
            datatype: "FP32",
            data: jpg_data,
        }],
        outputs: vec![OutputTensor {
            name: "OUTPUT0",
        }],
    };
    let json_bytes = serde_json::to_vec(&infer_payload).expect("failed to serialize json");
    let json_addr = json_bytes.as_ptr() as usize as u32;
    let json_size = json_bytes.len() as u32;
    unsafe {
        let ret = wasi_nn_compute(json_addr, json_size);
        if ret != 0 {
            println!("wasi_nn_compute failed with error code {}", ret);
        }
    }


    // unsafe {
        // _ = wasi_nn_get_stats();
    // }
    println!("Hello, world!");
}
