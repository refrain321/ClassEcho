import requests

# ================= 配置区 =================
# 填入你刚才那个一模一样的 API Key
API_KEY = "sk-jhppnayjorteqputhgxecvatrrdkoahroyzeuwykfqubhngo"  
# ==========================================

def summarize_text(text):
    url = "https://api.siliconflow.cn/v1/chat/completions"
    
    headers = {
        "Authorization": "Bearer " + API_KEY,
        "Content-Type": "application/json"
    }
    
    # 核心：这是大模型的“灵魂控制区”（Prompt）
    payload = {
        "model": "deepseek-ai/DeepSeek-V3", 
        "messages": [
            {
                "role": "system", 
                "content": "你是一个硬核课堂总结助手。请精准提取老师讲课文本中的核心知识点，用清晰的列表输出，并用一句话单独标注出这段话里的'易错点'或'考点'。"
            },
            {
                "role": "user", 
                "content": text
            }
        ]
    }

    print("🧠 正在呼叫云端大脑处理这段文本，请稍候...")
    
    response = requests.post(url, headers=headers, json=payload)
    
    if response.status_code == 200:
        result = response.json()
        
        # 解析返回的 JSON，一层层剥开拿到大模型的文字回复
        if "choices" in result:
            reply = result["choices"][0]["message"]["content"]
            print("\n📝 课堂重点提炼完毕：")
            print("=" * 40)
            print(reply)
            print("=" * 40)
        else:
            print("格式解析错误，未能找到返回文本。")
            
    else:
        print("\n❌ 请求失败！")
        print("状态码:", response.status_code)
        print("错误信息:", response.text)

if __name__ == "__main__":
    # 我们模拟一段信息密度极高的课堂内容
    mock_lecture_text = "同学们注意听，接下来讲的这个概念极度重要，期末肯定会考。我们来说说C++里面的‘引用’。引用跟指针不一样，引用其实就是一个变量的别名，它在声明的时候必须被初始化，而且一旦绑定了一个对象，就不能再换绑给别人了。不要把它和指针搞混了，指针是实实在在占用内存的，存的是地址，而引用在概念上不分配额外内存。听不懂没关系，先记住：声明引用必须初始化，且从一而终！"
    
    print("【原始课堂输入】")
    print(mock_lecture_text)
    print("-" * 40)
    
    summarize_text(mock_lecture_text)