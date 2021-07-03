def chunks(it, chunk_size):
    lst = list(it)
    return [lst[i:i + chunk_size] for i in range(0, len(lst), chunk_size)]

