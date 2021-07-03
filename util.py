def chunks(it, chunk_size):
    lst = list(it)
    return [lst[i:i + chunk_size] for i in range(0, len(lst), chunk_size)]

def merge(a, *rest):
    if len(rest) < 1:
        return a
    return {**a, **merge(rest[0], *rest[1:])}
