"""Two fixed local Honcho inference interfaces, with no management passthrough."""
import argparse
import importlib.util
import threading

EMBEDDING_MODEL = 'embeddinggemma2'


def validate_embedding_request(data):
    if not isinstance(data, dict) or data.get('model') != EMBEDDING_MODEL:
        raise ValueError('Only the configured embedding model is permitted')
    if set(data) - {'model', 'input', 'encoding_format', 'dimensions'}:
        raise ValueError('Unsupported embedding request fields')
    inputs = data.get('input')
    inputs = [inputs] if isinstance(inputs, str) else inputs
    if not isinstance(inputs, list) or not 1 <= len(inputs) <= 8:
        raise ValueError('A bounded text batch is required')
    if any(not isinstance(value, str) or not value for value in inputs):
        raise ValueError('Only nonempty text strings are permitted')
    if sum(len(value.encode()) for value in inputs) > 256 * 1024:
        raise ValueError('Embedding text exceeds policy')
    if data.get('encoding_format', 'float') != 'float':
        raise ValueError('Only float embeddings are permitted')
    if 'dimensions' in data and (type(data['dimensions']) is not int or data['dimensions'] != 768):
        raise ValueError('Only the configured embedding dimensions are permitted')
    result = dict(data)
    result['encoding_format'] = 'float'
    return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core', required=True)
    args = parser.parse_args(argv)
    spec = importlib.util.spec_from_file_location('cosmos_inference', args.core)
    core = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(core)
    chat = core.Gateway(('127.0.0.1', 18094), ('127.0.0.1', 8081))
    embeddings = core.Gateway(('127.0.0.1', 18093), ('127.0.0.1', 8081), endpoint='/v1/embeddings', model=EMBEDDING_MODEL, validator=validate_embedding_request)
    thread = threading.Thread(target=chat.serve_forever, daemon=True)
    thread.start()
    try:
        embeddings.serve_forever()
    finally:
        chat.shutdown()
        chat.server_close()
        embeddings.server_close()
        thread.join(timeout=5)


if __name__ == '__main__':
    main()
