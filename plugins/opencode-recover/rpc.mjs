import { Rpc } from '@opencode/plugin/rpc';

function object(properties) {
    return { type: 'object', properties, required: Object.keys(properties), additionalProperties: false };
}

const string = { type: 'string' };
const attestation = {
    pid: { type: 'integer', minimum: 1 },
    version: string,
    channel: string,
    home: string,
    env: object({
        XDG_CONFIG_HOME: string,
        XDG_DATA_HOME: string,
        XDG_STATE_HOME: string,
        XDG_CACHE_HOME: string,
        OPENCODE_DB: string,
    }),
    file: object({ dev: string, ino: string }),
};

export const Rex = Rpc.define({
    id: 'rex-recover',
    events: {},
    methods: {
        context: {
            input: object({ sessionID: string }),
            output: {
                oneOf: [
                    object({ state: { const: 'absent' }, ...attestation }),
                    object({ state: { const: 'unsupported' } }),
                    object({
                        state: { const: 'ready' },
                        ...attestation,
                        session: object({ id: string, location: object({ directory: string }) }),
                    }),
                ],
            },
        },
    },
});
