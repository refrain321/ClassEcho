from fastapi import FastAPI, UploadFile, File
import requests
import os
import shutil

# ================= 配置区 =================
API_KEY = "sk-jhppnayjorteqputhgxecvatrrdkoahroyzeuwykfqubhngo"  # 填入你的硅基流动 API Key
# ==========================================

app = FastAPI(title="ClassEcho API", description="AI 课堂伴读助手后端")

def get_text_from_audio(audio_path):
    url = "https://api.siliconflow.cn/v1/audio/transcriptions"
    headers = {"Authorization": "Bearer " + API_KEY}
    with open(audio_path, "rb") as file:
        files = {"file": ("upload.wav", file, "audio/wav")}
        data = {"model": "FunAudioLLM/SenseVoiceSmall", "language": "zh"}
        response = requests.post(url, headers=headers, files=files, data=data)
        
    if response.status_code == 200:
        return response.json().get("text", "")
    return None

def get_summary_from_text(text):
    url = "https://api.siliconflow.cn/v1/chat/completions"
    headers = {
        "Authorization": "Bearer " + API_KEY,
        "Content-Type": "application/json"
    }
    payload = {
        "model": "deepseek-ai/DeepSeek-V3", 
        "messages": [
            {
                "role": "system", 
                "content": "你是一个硬核课堂总结助手。请精准提取老师讲课文本中的核心知识点，用清晰的列表输出，并单独标注'考点'或'易错点'。"
            },
            {"role": "user", "content": text}
        ]
    }
    response = requests.post(url, headers=headers, json=payload)
    
    if response.status_code == 200:
        return response.json()["choices"][0]["message"]["content"]
    return None

# 这是暴露给手机端调用的核心接口
@app.post("/api/process_audio")
async def process_audio(file: UploadFile = File(...)):
    print(f"📥 接收到来自客户端的音频文件: {file.filename}")
    
    # 1. 暂存手机传过来的音频文件
    temp_file_path = f"temp_{file.filename}"
    with open(temp_file_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)
        
    # 2. 语音转文字
    raw_text = get_text_from_audio(temp_file_path)
    
    # 用完就删掉临时文件，保持服务器干净
    if os.path.exists(temp_file_path):
        os.remove(temp_file_path)
        
    if not raw_text:
        return {"status": "error", "message": "语音转写失败"}
        
    # 3. 提取总结
    summary = get_summary_from_text(raw_text)
    if not summary:
        return {"status": "error", "message": "总结提取失败", "raw_text": raw_text}
        
    # 4. 把处理好的数据打包返回给手机
    print("📤 处理完毕，正在将结果返回给客户端...")
    return {
        "status": "success",
        "raw_text": raw_text,
        "summary": summary
    }

# 运行服务器
if __name__ == "__main__":
    import uvicorn
    # 启动服务器，监听本地 8000 端口
    uvicorn.run(app, host="127.0.0.1", port=8000)